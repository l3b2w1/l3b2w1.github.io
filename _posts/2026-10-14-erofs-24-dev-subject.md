---
layout:     post
title:      EROFS dev subject
subtitle:   EROFS 设备专题
date:       2026-10-14
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
---

# EROFS `dev`（设备）专题：从 mount 初始化到文件访问

> **基线**：`/home/linux/erofs/linux-stable`（Linux 7.3-rc5），`fs/erofs/`
> 统一假设：`bs = 4096`；代码引用格式为「文件:行号」。
>
> 本文覆盖你点名的四个东西：**`sb->s_bdev` · `devs->flatdev` · `map->m_bdev` · `devs->extra_devices`**，
> 以及它们背后的 **`struct erofs_dev_context` / `erofs_device_info` / `erofs_map_dev`**。

---

## 0. 一句话速览

| 字段 | 归属 | 是什么 | 何时确定 |
|---|---|---|---|
| **`sb->s_bdev`** | VFS `super_block` | **主设备的块设备**（mknod 打开的 bdev） | mount 时由 VFS `get_tree_bdev_flags()` 设置 |
| **`devs->extra_devices`** | `sbi->devs`（`erofs_dev_context`） | **额外设备的个数**（不含主设备） | ① `-o device=` 时逐个 +1；② 无 `-o device=` 时按镜像声明的 `dsb->extra_devices` 循环创建 |
| **`devs->flatdev`** | 同上 | **"扁平设备"标志**：镜像声明了额外设备，但挂载时**一个都没给** | `erofs_scan_devices()`：镜像有 extra_devices 而 `devs->extra_devices == 0` ⇒ `flatdev = true` |
| **`map->m_bdev`** | `erofs_map_dev` | **解析后"这一块数据实际所在的"块设备** | 每次访问经 `erofs_map_dev()` 解析得出；主设备时 `= sb->s_bdev` |

一句话总结它们的分工：

```
sb->s_bdev             = 主设备（唯一由 VFS 直接持有）
devs->extra_devices    = 有几个"额外设备"
devs->flatdev          = 额外设备是否"扁平拼接在主设备之后"（不需要真的打开别的设备）
map->m_bdev            = 本次访问落到哪个块设备（= sb->s_bdev 或某个额外设备的 bdev）
```

---

## 1. 数据结构全景

#### 1.1 `struct erofs_dev_context`（`internal.h:66`）—— 挂在 `sbi->devs`

```c
struct erofs_dev_context {
        struct idr tree;              /* ★device_id → struct erofs_device_info* */
        struct rw_semaphore rwsem;    /* 保护 tree */

        unsigned int extra_devices;   /* ★额外设备个数 */
        bool flatdev;                 /* ★扁平设备标志 */
};
```

| 字段 | 写入点 | 读点 |
|---|---|---|
| `tree` | `idr_init`（`super.c:929`）；`idr_alloc`（`super.c:529` 解析选项 / `super.c:233` flatdev 建） | `idr_find`（`data.c:210`）、`idr_for_each_entry`（`data.c:224`、`super.c:220`）、`idr_for_each`（释放） |
| `rwsem` | `init_rwsem`（`super.c:930`） | 写锁：`super.c:528`（加设备）；读锁：`super.c:218/219/245`、`data.c:209/223` |
| `extra_devices` | `++`（`super.c:536` 每解析一个 `device=`；`super.c:238` flatdev 每建一个） | 数量校验（`super.c:199`）、`flatdev` 判定（`super.c:213`）、是否走反查支路（`data.c:222`） |
| `flatdev` | `super.c:214`（仅当 `ondisk_extradevs != 0 && extra_devices == 0`） | `erofs_init_device()` 是否打开设备（`super.c:137/147`）、`erofs_map_dev()`（`data.c:215/222`） |

- `tree` 是 **idr**：key 由 `idr_alloc()` 自动分配（从 0 开始），恰好等于 `device=` 出现的顺序，所以 `device_id=1` 对应 key 0。
- `rwsem` 保护 `tree` 的并发访问（读路径 down_read，`-o device=` 解析时 down_write）。

⚠️ 注意 `super.c:218-245` 用的是 `down_read()` 而非写锁去**新增** idr 条目——
这是上游现状（`extra_devices` 的 `++` 也在读锁下）。挂载是单线程且此时无并发访问者，
所以实践上安全，但读这段代码时容易误以为"读锁下不能改"。

#### 1.2 `struct erofs_device_info`（`internal.h:44`）—— 描述"一个设备"

```c
struct erofs_device_info {
        char *path;                   /* 设备/文件路径（来自 -o device= 或 device table 的 tag） */
        struct file *file;            /* 打开后的文件对象（bdev 或普通文件） */
        struct dax_device *dax_dev;   /* DAX 设备 */
        u64 fsoff, dax_part_off;      /* 文件系统在这台设备上的字节偏移 / DAX 分区偏移 */

        erofs_blk_t blocks;           /* 这台设备有多少块 */
        erofs_blk_t uniaddr;          /* ★这台设备在「统一地址空间」里的起始块号 */
};
```

主设备也用这个结构表示：**`sbi->dif0`**（`EROFS_SB(sb)->dif0`，`internal.h:84`）。

| 字段 | 主设备（dif0） | 额外设备（idr 中的 dif） | 主要读点 |
|---|---|---|---|
| `path` | 从不填（`NULL`） | `kstrdup()`（`super.c:523`，`-o device=`）或 `kmemdup_nul(dis->tag)`（`super.c:142`，从设备表 tag 拷） | 打开设备时用；释放时 `kfree` |
| `file` | `sbi->dif0.file`（fileio 模式才有，见 §3.4），bdev 模式**恒为 NULL** | `erofs_init_device()` 里打开（`super.c:148`） | `file_bdev(dif->file)`（`data.c:195`）、`m_dif->file`（fileio） |
| `dax_dev` | `fs_dax_get_by_bdev(sb->s_bdev, …)`（`super.c:710`） | `fs_dax_get_by_bdev(file_bdev(file), …)`（`super.c:159`） | `iomap->dax_dev`（`data.c:325`） |
| `fsoff` | `-o fsoffset=`（`super.c:555`） | **从不填**（恒 0） | `data.c:70`（metabuf）、`data.c:328`（iomap addr）、`zdata.c:1730`、`fileio.c:141/212` |
| `dax_part_off` | `fs_dax_get_by_bdev()` 回填（`super.c:711`） | 同上（`super.c:159`） | `data.c:330`（DAX 时加到 `iomap->addr`） |
| `blocks` | `dsb->blocks_lo`（`super.c:302`），48bit 时再或上 `rb.blocks_hi<<32`（`super.c:322`） | `dis->blocks_lo`（+48bit 时 `blocks_hi<<32`，`super.c:174`） | `total_blocks` 累加（`super.c:178`）、**反查区间上界**（`data.c:229`） |
| `uniaddr` | **从不赋值 ⇒ 恒为 0** | `dis->uniaddr_lo`（+48bit 时 `uniaddr_hi<<32`，`super.c:176`） | flatdev 平移（`data.c:216`）、**反查区间下界**（`data.c:227`） |

> ★ **两个容易踩空的点**
> ① `dif0.uniaddr` 在整棵树里**没有任何赋值处**——主设备的统一起始块就是 0，靠 `kzalloc` 的 0 兜底。
> ② 额外设备的 `fsoff` 永远是 0：`-o fsoffset=` 只作用于 `dif0`。

#### 1.3 `struct erofs_map_dev`（`internal.h:371`）—— 一次映射的"落点"

```c
struct erofs_map_dev {
        struct super_block *m_sb;
        struct erofs_device_info *m_dif;   /* 落在哪个 device_info */
        struct block_device *m_bdev;       /* ★落在哪个块设备 */

        erofs_off_t m_pa;                  /* 设备内的物理偏移 */
        unsigned int m_deviceid;           /* 设备号（0 = 主设备） */
};
```

| 字段 | 写入点 | 读点 |
|---|---|---|
| `m_sb` | `erofs_fill_from_devinfo()`（`data.c:192`） | fileio 提交时 `rq->sb = mdev->m_sb`（`fileio.c:73`） |
| `m_dif` | 同上（`data.c:193`）；额外设备时再被 `erofs_map_dev()` 重填（`data.c:220/232`） | `m_dif->fsoff`（`data.c:328`、`zdata.c:1730`、`fileio.c:141`）、`m_dif->file`（fileio）、`m_dif->dax_dev` |
| `m_bdev` | `fill_from_devinfo` 里仅当 `dif->file && S_ISBLK` 才设（`data.c:195-196`）；**主设备路径被 `data.c:207` 强制覆盖为 `sb->s_bdev`** | `iomap->bdev`（`data.c:327`）、`bio_alloc(mdev.m_bdev)`（`zdata.c:1726`）、bio 拆分判据（`zdata.c:1693`） |
| `m_pa` | 由调用方填（`data.c:316`、`zdata.c:1682`、`fileio.c:134`）；`erofs_map_dev()` 会**就地修改**（`data.c:216` 加 uniaddr / `data.c:230` 减 startoff） | `iomap->addr`、bio 的 `bi_sector` |
| `m_deviceid` | `erofs_map_blocks()` 开头清零（`data.c:159`）；chunk 路径由 `erofs_map_chunks()` 填（`data.c:139`：`last >> 48`） | `erofs_map_dev()` 的三路分支判据（`data.c:208`） |

> ★ `m_deviceid` 是**逻辑设备号**（1-based，0 表示主设备），不是 `idr` 的 key。
> `idr_find(&devs->tree, map->m_deviceid - 1)`（`data.c:210`）——**要减 1**。
> `idr` 的 key 由 `idr_alloc` 自动分配（从 0 开始），于是 `device_id = N` ⇒ `idr key = N-1`
> 恰好对上第 N 个 `device=`（前提是 flatdev 分支顺序分配）。

#### 1.4 `erofs_sb_info` 中的 dev 相关字段

| 字段 | 位置 | 说明 |
|---|---|---|
| `dif0` | `internal.h:84` | 主设备的 `erofs_device_info`，**不是放在 idr 里**，单独一个字段 |
| `devs` | `internal.h:102` | 额外设备上下文指针（挂载失败/卸载后置 `NULL`，`super.c:969`） |
| `total_blocks` | `internal.h:103` | **主 + 所有额外设备**的块数总和，供 `statfs` 用 |
| `device_id_mask` | `internal.h:114` | `u16`，从 on-disk `extra_devices` 算出，用于掩盖 `device_id` 的无效位 |
| `s_kobj` | `internal.h:136` | sysfs `/sys/fs/erofs/<devname>`（见 §6.3） |

#### 1.5 关系图

```
                    VFS
        sb->s_bdev ──────────────┐  （主块设备，mount 时由 VFS 设置）
                                 │
        sbi->dif0  ←─────────────┘  （主设备的 device_info：fsoff / dax_dev / blocks）
            │
        sbi->devs  ── extra_devices = N
            │      ── flatdev = ?
            └── tree (idr)
                  ├── key 0 → dif (device_id=1)  → file/bdev/dax_dev + blocks + uniaddr
                  ├── key 1 → dif (device_id=2)
                  └── ...

        一次访问：
        erofs_map_blocks() → map.m_pa / map.m_deviceid
              │
              ▼
        erofs_map_dev()  ── 填 mdev.m_dif / mdev.m_bdev / mdev.m_pa
              │
              ▼
        iomap->bdev = mdev.m_bdev        （非压缩 / DAX 走 dax_dev）
        bio_alloc(mdev.m_bdev, ...)      （压缩）
        rq->iocb.ki_filp = mdev->m_dif->file   （fileio 文件后端）
```

#### 1.6 条件编译桩（`CONFIG_EROFS_FS_BACKED_BY_FILE`）

`CONFIG_EROFS_FS_BACKED_BY_FILE` 关闭时，fileio 接口退化为空桩，链接不破：

```c
/* internal.h:397-400 */
#ifdef CONFIG_EROFS_FS_BACKED_BY_FILE
int erofs_read_meta_folio(struct file *file, struct folio *folio);
#else
#define erofs_read_meta_folio NULL
#endif

/* internal.h:506-511 */
#ifdef CONFIG_EROFS_FS_BACKED_BY_FILE
struct bio *erofs_fileio_bio_alloc(struct erofs_map_dev *mdev);
void erofs_fileio_submit_bio(struct bio *bio);
#else
static inline struct bio *erofs_fileio_bio_alloc(struct erofs_map_dev *mdev) { return NULL; }
static inline void erofs_fileio_submit_bio(struct bio *bio) {}
#endif
```

⇒ 调用侧（`zdata.c:1724` 等）因此可以**无条件**写
`if (erofs_is_fileio_mode(...)) bio = erofs_fileio_bio_alloc(&mdev);`——
fileio 模式本身就被 `dif0.file` 判死，桩不会被真正用到。

---

## 2. on-disk 布局：设备表

#### 2.1 `struct erofs_deviceslot`（`erofs_fs.h:43`）

```c
struct erofs_deviceslot {
	u8     tag[64];      /* digest(sha256) 等标识 */
	__le32 blocks_lo;    /* 该设备总块数（低 32 位） */
	__le32 uniaddr_lo;   /* 统一地址空间中的起始块（低 32 位） */
	__le16 blocks_hi;    /* 总块数高 16 位 */
	__le16 uniaddr_hi;   /* 起始块高 16 位 */
	u8     reserved[52];
};
#define EROFS_DEVT_SLOT_SIZE  sizeof(struct erofs_deviceslot)   /* = 128 */
```

- `erofs_fs.h:462` 有 `BUILD_BUG_ON(sizeof(struct erofs_deviceslot) != 128);` —— **固定 128 B**
- 表起点：`pos = le16_to_cpu(dsb->devt_slotoff) * EROFS_DEVT_SLOT_SIZE`（`super.c:217`）
  实测样本里 `devt_slotoff = 9` ⇒ **1152**
- 每解析完一个槽：`*pos += EROFS_DEVT_SLOT_SIZE`（`super.c:179`）

#### 2.2 superblock 里的两个设备字段

| 字段 | 行 | 说明 |
|---|---|---|
| `__le16 extra_devices` | `erofs_fs.h:79` | 「除主设备外还有几个设备」，实测 `--blobdev` 镜像 = **1** |
| `__le16 devt_slotoff` | `erofs_fs.h:80` | 设备表起点（单位 = 128 B 的槽） |

#### 2.3 字段偏移复核

按 `struct erofs_super_block` 逐字段累加：`magic` 0 → `blkszbits` 12 → `rb` 14-15 →
`inos` 16 → `epoch` 24 → `blocks_lo` 36 → `meta_blkaddr` 40 → `xattr_blkaddr` 44 →
`uuid` 48 → `volume_name` 64 → `feature_incompat` 80 → `u1` 84-85 →
**`extra_devices` 86** → **`devt_slotoff` 88**。
与 §8 实测锚点（od 读到的偏移 86/88）一致 ✓。

---

## 3. mount 初始化：每一步

#### 3.1 `sb->s_bdev` 从哪来

```c
/* super.c:787 erofs_fc_get_tree() */
ret = get_tree_bdev_flags(fc, erofs_fc_fill_super, ...);   /* 803 行 */
```

`get_tree_bdev_flags()` 是 VFS 提供的通用实现：解析 `fc->source`（如 `/dev/vdb`）→ 打开块设备 →
**设置 `sb->s_bdev`** → 再回调 `erofs_fc_fill_super()`。

⇒ EROFS 自己**不打开主设备**，主设备由 VFS 搞定，`sb->s_bdev` 就是它。
（file-backed 挂载时 `sb->s_bdev == NULL`，走另一条路，见 §3.4。）

#### 3.2 `sbi->devs` 的创建

```c
/* super.c:914 erofs_init_fs_context() */
sbi->devs = kzalloc_obj(struct erofs_dev_context);      /* 922 */
if (!sbi->devs) { ... }
fc->s_fs_info = sbi;

idr_init(&sbi->devs->tree);          /* super.c:929 */
init_rwsem(&sbi->devs->rwsem);       /* super.c:930 */
```

此时 `extra_devices = 0`、`flatdev = false`（kzalloc 清零）。

#### 3.3 解析 `-o device=`（只记路径，不打开）

```c
/* super.c:519  case Opt_device: */
dif = kzalloc_obj(*dif);
dif->path = kstrdup(param->string, GFP_KERNEL);          /* ★只保存路径字符串（523） */
down_write(&sbi->devs->rwsem);
ret = idr_alloc(&sbi->devs->tree, dif, 0, 0, GFP_KERNEL); /* 分配 id（key） */
up_write(&sbi->devs->rwsem);
...
++sbi->devs->extra_devices;                                /* ★计数 +1（536） */
```

关键：**这一步不打开设备**，只是把路径按"出现顺序"放进 idr。
所以 `-o device=A,device=B` ⇒ A 是 `device_id=1`、B 是 `device_id=2`（顺序必须对应镜像里的 device table）。

#### 3.4 `dif0`（主设备的 device_info）填什么

**① `blocks`：两处赋值（含 48bit 高位）**

```c
/* super.c:302 erofs_read_superblock() */
sbi->dif0.blocks = le32_to_cpu(dsb->blocks_lo);
...
/* super.c:320-323 */
if (erofs_sb_has_48bit(sbi) && dsb->rootnid_8b) {
	sbi->root_nid = le64_to_cpu(dsb->rootnid_8b);
	sbi->dif0.blocks = sbi->dif0.blocks |
			((u64)le16_to_cpu(dsb->rb.blocks_hi) << 32);
}
sbi->packed_nid = le64_to_cpu(dsb->packed_nid);          /* 327 */
```

⇒ 48bit 布局下主设备块数的高 16 位藏在 `dsb->rb.blocks_hi`（`erofs_fs.h:63` 的 `__packed rb` 联合体）里。

**② `dax_dev`（bdev 模式）**

```c
/* super.c:710 erofs_fc_fill_super() —— 块设备挂载分支 */
sbi->dif0.dax_dev = fs_dax_get_by_bdev(sb->s_bdev,
		&sbi->dif0.dax_part_off, NULL, NULL);
```

**③ `fsoff` 与 `-o fsoffset=`**

```c
/* super.c:415 选项声明 */
fsparam_u64("fsoffset",  Opt_fsoffset),
/* super.c:554 */
case Opt_fsoffset:
	sbi->dif0.fsoff = result.uint_64;
	break;
/* super.c:727 对齐校验 */
if (sbi->dif0.fsoff & (sb->s_blocksize - 1))
	return invalfc(fc, "fsoffset %llu is not aligned to block size %lu",
		       sbi->dif0.fsoff, sb->s_blocksize);
/* super.c:1116 /proc/mounts 回显 */
if (sbi->dif0.fsoff)
	seq_printf(seq, ",fsoffset=%llu", sbi->dif0.fsoff);
```

作用：**file-backed 挂载时，镜像在文件里的起始字节偏移**。
读数据时统一加它：`iomap->addr = mdev.m_dif->fsoff + mdev.m_pa`（`data.c:328`），
连元数据都加：`buf->off = sbi->dif0.fsoff`（`data.c:70`）。
⇒ 只有 `dif0` 有这个偏移，**额外设备恒为 0**。

**④ `file`：fileio 模式下的三个来源**

```c
/* 来源 1：mount -o fd=N 或 fsopen 传 file */
/* super.c:443 erofs_fc_parse_source()，case fs_value_is_file: */
sbi->dif0.file = no_free_ptr(param->file);       /* super.c:467 */

/* 来源 2：get_tree_bdev_flags() 返回 -ENOTBLK 时回退 */
/* super.c:817-830 */
if (IS_ENABLED(CONFIG_EROFS_FS_BACKED_BY_FILE) && ret == -ENOTBLK) {
	file = filp_open(fc->source, O_RDONLY | O_LARGEFILE, 0);
	if (IS_ERR(file))
		return PTR_ERR(file);
	sbi->dif0.file = file;
	if (S_ISREG(file_inode(sbi->dif0.file)->i_mode) &&
	    sbi->dif0.file->f_mapping->a_ops->read_folio)
		return get_tree_nodev(fc, erofs_fc_fill_super);
}
```

判定宏（`internal.h:158`）：

```c
static inline bool erofs_is_fileio_mode(struct erofs_sb_info *sbi)
{
	return IS_ENABLED(CONFIG_EROFS_FS_BACKED_BY_FILE) && sbi->dif0.file;
}
```

⇒ **`dif0.file` 非 NULL 即 fileio 模式**，`sb->s_bdev` 为 NULL，全部 I/O 走 `vfs_iocb_iter_read()`。

fileio 模式的三条硬约束：
1. 必须是 **regular file** 且 `a_ops->read_folio` 存在（`super.c:807-808`）
2. 不能叠在另一个 file-backed EROFS 或 stacked fs 上（`super.c:689`，`s_stack_depth` 检查）
3. `sb->s_blocksize` 只能设为 `PAGE_SIZE`（`super.c:693-694`）

**⑤ `uniaddr`：从不赋值 ⇒ 隐含 0**

全树 `grep dif0.uniaddr` **无任何写入点**。语义上正确：主设备是统一地址空间的基准，起点必然是 0。
额外设备才有真正的 `uniaddr`。

⇒ `dif0` **没有 `file`/`path`**（bdev 模式）：主设备由 `sb->s_bdev` 直接表达。

#### 3.5 `erofs_scan_devices()`：读 device table（`super.c:183`）

```c
sbi->total_blocks = sbi->dif0.blocks;                 /* 先算主设备的块数（193） */
ondisk_extradevs = erofs_sb_has_device_table(sbi) ? le16_to_cpu(dsb->extra_devices) : 0;

/* ① 数量必须一致（super.c:199） */
if (sbi->devs->extra_devices &&
    ondisk_extradevs != sbi->devs->extra_devices) {
	erofs_err(sb, "extra devices don't match (ondisk %u, given %u)", ...);
	return -EINVAL;
}
if (!ondisk_extradevs) return 0;                       /* 没有额外设备，直接返回（210） */

/* ② flatdev 的判定（super.c:213） */
if (!sbi->devs->extra_devices)
	sbi->devs->flatdev = true;                     /* ★声明了但没给 ⇒ 扁平 */

/* ③ device_id 掩码（super.c:216） */
sbi->device_id_mask = roundup_pow_of_two(ondisk_extradevs + 1) - 1;

/* ④ 逐个初始化 */
pos = le16_to_cpu(dsb->devt_slotoff) * EROFS_DEVT_SLOT_SIZE;   /* device table 起点（217） */
if (sbi->devs->extra_devices) {
	/* 给了 -o device= ⇒ 遍历已有的（顺序即 device_id） */
	idr_for_each_entry(&sbi->devs->tree, dif, id)
		erofs_init_device(&buf, sb, dif, &pos);
} else {
	/* 没给 ⇒ 按 slot 顺序创建（flatdev 场景） */
	for (id = 0; id < ondisk_extradevs; id++) {
		dif = kzalloc_obj(*dif);
		idr_alloc(&sbi->devs->tree, dif, 0, 0, GFP_KERNEL);
		++sbi->devs->extra_devices;
		erofs_init_device(&buf, sb, dif, &pos);
	}
}
```

**数量校验的语义**：只校验「给了但数量不符」，不校验「一个都没给」——后者走 flatdev。

**`flatdev` 的三态含义**

| 镜像 `extra_devices` | 挂载给 `-o device=` | 结果 |
|---|---|---|
| 0 | 无 | 单设备，`flatdev=false` |
| >0 | 给了 N 个（N 必须相等） | 真多设备，`flatdev=false` |
| >0 | **一个都没给** | **`flatdev=true`**：假设所有设备在**主设备之后连续拼接**，不打开任何新设备 |

**`device_id_mask` 的计算与用途**

```c
/* super.c:216 */
sbi->device_id_mask = roundup_pow_of_two(ondisk_extradevs + 1) - 1;
```

| `ondisk_extradevs` | `+1` | `roundup_pow_of_two` | `-1` | mask | 可表示的 device_id |
|---|---|---|---|---|---|
| 0 | 1 | 1 | 0 | `0x0` | 只有 0（主设备） |
| 1 | 2 | 2 | 1 | `0x1` | 0, 1 |
| 2 | 3 | 4 | 3 | `0x3` | 0..3 |
| 3 | 4 | 4 | 3 | `0x3` | 0..3 |
| 5 | 6 | 8 | 7 | `0x7` | 0..7 |

用处只有一处 —— 解码 8 B chunk index 时掩盖无效位：

```c
/* data.c:121 */
addr |= (u64)(le16_to_cpu(idx[nr].device_id) &
	EROFS_SB(sb)->device_id_mask) << 48;
```

⚠️ 若镜像**没有** device table（`ondisk_extradevs == 0`），`super.c:210` 会**提前 return 0**，
`device_id_mask` 保持 0 —— 此时 8 B 索引里的 `device_id` 被全掩盖为 0，chunk 只能落在主设备。

#### 3.6 `erofs_init_device()`：打开设备 / 填 `blocks` `uniaddr`（`super.c:125`）

```c
dis = erofs_read_metabuf(buf, sb, *pos, false);        /* 读一个 erofs_deviceslot（128 B） */

/* ① 路径：没给 -o device= 时从 tag 里取 */
if (!sbi->devs->flatdev && !dif->path) {
	if (!dis->tag[0]) { erofs_err("empty device tag"); return -EINVAL; }
	dif->path = kmemdup_nul(dis->tag, sizeof(dis->tag), GFP_KERNEL);   /* 142 */
}

/* ② 打开设备：★flatdev 时跳过（不打开任何东西） */
if (!sbi->devs->flatdev) {
	file = erofs_is_fileio_mode(sbi) ?
			filp_open(dif->path, O_RDONLY | O_LARGEFILE, 0) :      /* 文件后端 */
			fs_bdev_file_open_by_path(dif->path, BLK_OPEN_READ, sb->s_type, sb);
	if (IS_ERR(file)) {
		if (file == ERR_PTR(-ENOTBLK))
			return -EINVAL;              /* 路径不是块设备 */
		return PTR_ERR(file);
	}

	if (!erofs_is_fileio_mode(sbi)) {
		dif->dax_dev = fs_dax_get_by_bdev(file_bdev(file),
				&dif->dax_part_off, NULL, NULL);                    /* 159 */
	} else if (!S_ISREG(file_inode(file)->i_mode)) {
		fput(file);
		return -EINVAL;                      /* fileio 下必须是普通文件 */
	}
	if (!dif->dax_dev && test_opt(&sbi->opt, DAX_ALWAYS)) {
		erofs_info(sb, "DAX unsupported by %s. Turning off DAX.", dif->path);
		clear_opt(&sbi->opt, DAX_ALWAYS);
	}
	dif->file = file;
}

/* ③ 无条件填：块数与统一起始地址（48bit 时拼高位） */
_48bit = erofs_sb_has_48bit(sbi);
dif->blocks  = le32_to_cpu(dis->blocks_lo)  | (_48bit ? (u64)le16_to_cpu(dis->blocks_hi)  << 32 : 0);   /* 174 */
dif->uniaddr = le32_to_cpu(dis->uniaddr_lo) | (_48bit ? (u64)le16_to_cpu(dis->uniaddr_hi) << 32 : 0);  /* 176 */
sbi->total_blocks += dif->blocks;                                                                        /* 178 */
*pos += EROFS_DEVT_SLOT_SIZE;                          /* 下一个 slot（179） */
```

打开方式的分流：

| 分支 | 打开方式 | 后续检查 | `dif->file` |
|---|---|---|---|
| **flatdev** | 不开（整个 `if` 跳过） | 无 | `NULL` |
| **fileio** | `filp_open()` | 必须 `S_ISREG` | 普通文件的 `struct file*` |
| **bdev** | `fs_bdev_file_open_by_path()` | `-ENOTBLK ⇒ -EINVAL`；尝试取 `dax_dev` | 块设备的 `struct file*` |

⇒ 注意 `fs_bdev_file_open_by_path()` 传了 `sb` 作为 holder —— **设备被这个 superblock 声明占用**，
卸载时须用 `fs_bdev_file_release(dif->file, sb)` 成对释放（`super.c:865`）。

⇒ **即使是 `flatdev`，`blocks` / `uniaddr` 也会被填上**——因为扁平模式要靠 `uniaddr` 做地址平移。

#### 3.7 DAX 与设备的三处交互

| 位置 | 行为 |
|---|---|
| `super.c:206` | 主设备无 `dax_dev` 且指定 `DAX_ALWAYS` ⇒ 关掉 DAX 并 `erofs_info` |
| `super.c:165` | 额外设备无 `dax_dev` 且指定 `DAX_ALWAYS` ⇒ 关掉 DAX 并 `erofs_info`（**整 fs 生效**） |
| `super.c:731` | `DAX_ALWAYS` 且 `blkszbits != PAGE_SHIFT` ⇒ 关掉 DAX |

用法：`iomap->dax_dev = mdev.m_dif->dax_dev`（`data.c:325`），
且 `iomap->addr += mdev.m_dif->dax_part_off`（`data.c:330`）。

#### 3.8 remount 不能加减设备：`device=` 被静默丢弃

`erofs_fc_reconfigure()`（`super.c:835`）**只拷贝挂载选项**，完全不碰 `devs`：

```c
/* super.c:835 */
static int erofs_fc_reconfigure(struct fs_context *fc)
{
	...
	sbi->opt = new_sbi->opt;            /* ★只换 opt，devs 不动 */
	fc->sb_flags |= SB_RDONLY;
	return 0;
}
```

remount 时 VFS 会 `init_fs_context()` 一个**新的** sbi，`mount -o remount,device=/dev/vdd`
里的 `device=` 会被 `erofs_fc_parse_param()` 正常解析进 `new_sbi->devs`
（分配 dif、`idr_alloc`、`extra_devices++`）——但 reconfigure 不看它，
最后 `erofs_fc_free()` → `erofs_sb_free()` → `erofs_free_dev_context()`
把 new_sbi 的 devs **整体释放**。

⇒ **设备集合在初次挂载后固定**；remount 传 `device=` 既不报错也不生效（静默忽略）。

---

## 4. 文件访问：`dev` 怎么被用

#### 4.1 总起：四套 aops 与 dev 的关系

`erofs_get_aops()`（`internal.h:442`）按 inode 的 datalayout 与挂载模式选 aops：

```c
/* internal.h:442 erofs_get_aops() */
if (erofs_inode_is_data_compressed(EROFS_I(realinode)->datalayout))
	return &z_erofs_aops;                    /* zdata.c:1920，非 iomap 路径 */
if (IS_ENABLED(CONFIG_EROFS_FS_BACKED_BY_FILE) &&
	erofs_is_fileio_mode(EROFS_SB(realinode->i_sb)))
	return &erofs_fileio_aops;               /* fileio.c */
return &erofs_aops;                          /* data.c:435，iomap 路径 */
```

| aops | 适用 | 是否经 `erofs_map_dev()` | 能否指向额外设备 |
|---|---|---|---|
| `erofs_aops`（`data.c:435`） | 非压缩 + bdev 模式 | ✅（`data.c:317`） | ✅ `iomap->bdev = mdev.m_bdev`（`data.c:327`） |
| `z_erofs_aops`（`zdata.c:1920`） | 压缩 | ✅（`zdata.c:1685`） | ✅ `bio_alloc(mdev.m_bdev)`（`zdata.c:1726`） |
| `erofs_fileio_aops`（`fileio.c`） | 非压缩 + fileio | ✅（`fileio.c:137`） | ✅ `mdev->m_dif->file`（`fileio.c:72`） |
| **`z_erofs_iomap_report_ops`**（`zmap.c:836`） | **仅 FIEMAP / SEEK_HOLE** | ❌ | ❌ 恒为主设备 |

（`erofs_aops` 的注释原话："for uncompressed (aligned) files and raw access for other files"。）

#### 4.2 元数据读取：三个 mapping 来源与两个例外

```c
/* data.c:54 erofs_init_metabuf() */
static int erofs_init_metabuf(struct erofs_buf *buf, struct super_block *sb, bool in_metabox)
{
	buf->mc = false;
	if (in_metabox) {
		buf->mapping = sbi->metabox_inode->i_mapping;   /* metabox：伪 inode */
		return 0;
	}
	if (erofs_is_fileio_mode(sbi)) {
		buf->mapping = sbi->managed_cache->i_mapping;   /* managed cache */
		buf->mc = true;
	} else {
		buf->off = sbi->dif0.fsoff;
		buf->mapping = sb->s_bdev->bd_mapping;           /* ★主设备 */
	}
	return 0;
}
```

**读法（精确版）**：mapping 三选一——metabox 伪 inode / managed cache / 主设备 `bd_mapping`。
"元数据**永远**不从额外设备读"这句话**过于绝对**，准确说法是：

- **bdev 模式的经典元数据**（inode / dirent / xattr / device table，`!in_metabox`）：
  `sb->s_bdev->bd_mapping` 直连，**完全不经过** `erofs_map_dev()` ⇒ 必然主设备 ✓
- **例外 ① metabox 页**：mapping 是 `metabox_inode->i_mapping`，页缺失时由该 inode 的
  aops 填充（`erofs_iget` → `erofs_get_aops`，`inode.c:259`）——即**正常数据映射路径**
  （`erofs_map_blocks` + `erofs_map_dev`）⇒ metabox 内容**可以**落在额外设备上
- **例外 ② fileio 模式的 managed_cache 页**：
  `read_cache_folio(..., buf->mc ? erofs_read_meta_folio : NULL)`（`data.c:42`）
  ⇒ 页缺失时 `erofs_read_meta_folio()`（`fileio.c:198`）显式调
  `erofs_map_dev(inode->i_sb, &io.dev)` ⇒ **技术上经过多设备解析**
  （正常镜像元数据地址不会命中 blob 区间，但代码路径是通的）

```c
/* fileio.c:198 erofs_read_meta_folio() */
struct erofs_fileio io = {
	.dev = { .m_pa = folio_pos(folio), },      /* 统一地址 */
};
err = erofs_map_dev(inode->i_sb, &io.dev);          /* ★显式经 map_dev */
...
io.rq->bio.bi_iter.bi_sector = (io.dev.m_dif->fsoff + io.dev.m_pa) >> 9;
```

| 元数据种类 | bdev 模式 | fileio 模式 |
|---|---|---|
| 经典元数据（inode/dirent/xattr/devtable） | `sb->s_bdev->bd_mapping` 直连，**不经 map_dev** | managed_cache + `erofs_read_meta_folio`，**经 map_dev** |
| metabox 页 | metabox inode 的 aops（数据路径），**经 map_dev** | 同左 |

#### 4.3 `erofs_map_dev()`：统一地址 → 具体设备的三条支路（`data.c:199`）

```c
int erofs_map_dev(struct super_block *sb, struct erofs_map_dev *map)
{
	struct erofs_dev_context *devs = EROFS_SB(sb)->devs;
	struct erofs_device_info *dif;
	erofs_off_t startoff;
	int id;

	erofs_fill_from_devinfo(map, sb, &EROFS_SB(sb)->dif0);
	map->m_bdev = sb->s_bdev;	/* use s_bdev for the primary device */
	if (map->m_deviceid) {
		down_read(&devs->rwsem);
		dif = idr_find(&devs->tree, map->m_deviceid - 1);
		if (!dif) {
			up_read(&devs->rwsem);
			return -ENODEV;
		}
		if (devs->flatdev) {
			map->m_pa += erofs_pos(sb, dif->uniaddr);
			up_read(&devs->rwsem);
			return 0;
		}
		erofs_fill_from_devinfo(map, sb, dif);
		up_read(&devs->rwsem);
	} else if (devs->extra_devices && !devs->flatdev) {
		down_read(&devs->rwsem);
		idr_for_each_entry(&devs->tree, dif, id) {
			if (!dif->uniaddr)
				continue;

			startoff = erofs_pos(sb, dif->uniaddr);
			if (map->m_pa >= startoff &&
			    map->m_pa < startoff + erofs_pos(sb, dif->blocks)) {
				map->m_pa -= startoff;          /* ★改成设备内相对地址 */
				erofs_fill_from_devinfo(map, sb, dif);
				break;
			}
		}
		up_read(&devs->rwsem);
	}
	return 0;
}
```

| 支路 | 触发条件 | 语义 |
|---|---|---|
| ① `m_deviceid != 0`（`data.c:208`） | chunk 索引带 `device_id` | 显式指定第 N 个设备 |
| ② flatdev 且 `m_deviceid != 0`（`data.c:215`） | 没给 `device=` | 只平移地址 `m_pa += uniaddr`，**不换设备** |
| ③ `m_deviceid == 0` 且有额外设备（`data.c:222`） | startblk 直接编址 | **按统一地址区间反查**归属设备 |

支路 ③ 解释了"为什么非 chunk 的普通文件也能自动落到 blob 设备上"：
mkfs 给这种 inode 的 `startblk` 直接写成**统一地址**（跨过 `uniaddr`）。
注意 `if (!dif->uniaddr) continue;` —— `uniaddr == 0` 的设备（也就是主设备地址起点）会被跳过，
避免把主设备的地址误判成别人（这也正是 `dif0.uniaddr` 恒为 0 的用意，见 §3.4⑤）。

#### 4.4 `erofs_fill_from_devinfo()`：`m_bdev` 的两个来源（`data.c:189`）

```c
static void erofs_fill_from_devinfo(struct erofs_map_dev *map,
		struct super_block *sb, struct erofs_device_info *dif)
{
	map->m_sb = sb;
	map->m_dif = dif;
	map->m_bdev = NULL;
	if (dif->file && S_ISBLK(file_inode(dif->file)->i_mode))
		map->m_bdev = file_bdev(dif->file);       /* 额外设备：从 file 取 bdev */
}
```

⇒ **`map->m_bdev` 的两个来源**：
- 主设备：`map->m_bdev = sb->s_bdev`（`data.c:207` 显式赋值，**覆盖** `fill_from_devinfo` 里的 NULL；注释就写着 `use s_bdev for the primary device`）
- 额外设备：`fill_from_devinfo` 里 `file_bdev(dif->file)`（前提是该设备的 file 是块设备）

⇒ `m_bdev` 的赋值被显式覆盖过一次：`erofs_fill_from_devinfo()` 里先 `m_bdev = NULL`、
只有 `S_ISBLK` 时才设；随后 `erofs_map_dev()` 又用 `map->m_bdev = sb->s_bdev`
**无条件覆盖**——这是主设备路径的权威赋值。
fileio 模式下 `dif->file` 是普通文件（非 `S_ISBLK`）⇒ `m_bdev` 保持 NULL，改走 `m_dif->file`。

#### 4.5 非压缩数据读：iomap 用 `m_bdev`

```c
/* data.c:289 erofs_iomap_begin() —— 仅数据（非 EROFS_MAP_META） */
mdev = (struct erofs_map_dev) { .m_deviceid = map.m_deviceid, .m_pa = map.m_pa };   /* 316 */
ret = erofs_map_dev(sb, &mdev);
if (ret) return ret;

if (flags & IOMAP_DAX)
	iomap->dax_dev = mdev.m_dif->dax_dev;      /* DAX：用 dax_dev */
else
	iomap->bdev = mdev.m_bdev;                 /* ★普通：用 m_bdev */
iomap->addr = mdev.m_dif->fsoff + mdev.m_pa;       /* 设备内偏移（含 fsoff 偏移） */
if (flags & IOMAP_DAX)
	iomap->addr += mdev.m_dif->dax_part_off;
```

注意 `iomap->addr = fsoff + m_pa`：支持"文件系统不是从设备 0 开始"（`-o fsoffset=` / 分区偏移）。

#### 4.6 压缩数据读：`bio_alloc(mdev.m_bdev)`

```c
/* zdata.c:1641 z_erofs_submit_queue() 的提交循环 */
(void)erofs_map_dev(sb, &mdev);                                    /* 1685 */
cur = mdev.m_pa;
...
/* ① bio 需要拆分的两个条件：物理不连续 或 设备变了 */
if (bio && (cur != last_pa || bio->bi_bdev != mdev.m_bdev)) {      /* 1693 */
	if (erofs_is_fileio_mode(EROFS_SB(sb))) erofs_fileio_submit_bio(bio);
	else submit_bio(bio);
	bio = NULL;
}
...
/* ② 分配 bio 时绑定设备 */
if (!bio) {
	if (erofs_is_fileio_mode(EROFS_SB(sb)))
		bio = erofs_fileio_bio_alloc(&mdev);                      /* 1724 */
	else
		bio = bio_alloc(mdev.m_bdev, BIO_MAX_VECS, REQ_OP_READ, GFP_NOIO);  /* ★1726 */
	bio->bi_end_io = z_erofs_endio;
	bio->bi_iter.bi_sector = (mdev.m_dif->fsoff + cur) >> 9;      /* 1730 */
	...
}
```

⇒ `bi_bdev != mdev.m_bdev` 这个判断很关键：**同一个 bio 不能跨设备**，
遇到不同设备（或地址不连续）就必须先提交、再开新 bio。

#### 4.7 压缩 inode 的 FIEMAP / SEEK_HOLE 上报：硬编码 `s_bdev`

```c
/* zmap.c:793  z_erofs_iomap_begin_report() */
static int z_erofs_iomap_begin_report(struct inode *inode, loff_t offset, ...)
{
	...
	iomap->bdev = inode->i_sb->s_bdev;      /* zmap.c:805  ★硬编码主设备 */
```

⚠️ **这不是读路径。** 这套 ops（`z_erofs_iomap_report_ops`，`zmap.c:836`）
全树只有**两个**使用者：

| 使用者 | 位置 | 用途 |
|---|---|---|
| `erofs_fiemap()` | `data.c:386` | `ioctl(FS_IOC_FIEMAP)` / `filefrag` |
| `erofs_file_llseek()` | `data.c:510` | `SEEK_HOLE` / `SEEK_DATA` |

而**真正读压缩数据**走的是 `z_erofs_aops`（§4.1），压根不经过 iomap。

⇒ 结论：

1. **压缩数据是可以落在额外设备上的**——实际 I/O 走 `z_erofs_aops` → `erofs_map_dev()` → `bio_alloc(mdev.m_bdev)`，
   与 §4.6 一致。
2. 但 `zmap.c` 全文**没有任何** `m_deviceid` / `erofs_map_dev` / `m_bdev`（已 grep 确认），
   即**压缩映射层本身不感知设备**。
3. 因此在「压缩 + 多设备 + 数据确实在 blob 上」的组合下，`FIEMAP` 报出来的
   `iomap->bdev` 会是**主设备而不是实际设备** —— 这是上游的一个已知简化（上报接口只关心
   偏移/长度够不够拼出 extent 图，bdev 填主设备通常够用，因为 fiemap 用户态一般只看
   `fe_physical` 与 `fe_logical`）。**值得记为一条潜在不一致**。

#### 4.8 fileio（文件后端）：用 `m_dif->file`，没有 bdev

```c
/* fileio.c:66 erofs_fileio_rq_alloc() */
bio_init(&rq->bio, NULL, rq->bvecs, ARRAY_SIZE(rq->bvecs), REQ_OP_READ);  /* bdev=NULL */
rq->iocb.ki_filp = mdev->m_dif->file;      /* ★用文件指针做 VFS 读（72） */
rq->sb = mdev->m_sb;                       /* 73 */
```

```c
/* fileio.c:141 / 212 —— 计算文件内的字节偏移 */
(io.dev.m_dif->fsoff + io.dev.m_pa) >> 9;
```

fileio 按"物理不连续 **或 deviceid 变了**"拆请求（`fileio.c:126`）：

```c
if (io->rq && (map->m_pa + ofs != io->dev.m_pa ||
	       map->m_deviceid != io->dev.m_deviceid)) {
	erofs_fileio_rq_submit(io->rq);
	io->rq = NULL;
}
```

⇒ fileio 模式下 `map->m_bdev` 是 NULL（因为 `fill_from_devinfo` 只在 `S_ISBLK` 时设 bdev），
数据走 `vfs_iocb_iter_read()`。

#### 4.9 chunk-based 文件：`m_deviceid` 从哪来

chunk 索引项把 **`device_id` 编在块地址的 bit48 以上**（见 `erofs_map_chunks` 专题），
`erofs_map_dev()` 收到 `m_deviceid` 后按 §4.3 的支路①/② 处理：

```
chunk index 里的 device_id ──► map->m_deviceid ──► erofs_map_dev()
                                                    ├─ flatdev → m_pa += uniaddr（不换设备）
                                                    └─ 否则   → idr_find → 换 m_dif / m_bdev
```

解码处的掩码有两个（`data.c:95 / 121`）：

```c
/* data.c:95 —— 块地址有效位 */
erofs_blk_t addrmask = (vi->chunkformat & EROFS_CHUNK_FORMAT_48BIT) ?
	BIT_ULL(48) - 1 : BIT_ULL(32) - 1;

/* data.c:121-122 —— device_id 有效位 */
addr |= (u64)(le16_to_cpu(idx[nr].device_id) &
	EROFS_SB(sb)->device_id_mask) << 48;
```

⇒ chunk 是数据落到另一台设备上的**显式入口**（索引里写明 `device_id`）。
注意还有第二个**隐式入口**：非 chunk 的普通文件把 `startblk` 直接编成跨过 `uniaddr` 的
统一地址，由 `erofs_map_dev()` 的支路③按区间反查命中（见 §4.3）。

#### 4.10 ishare（inode 共享）：数据 I/O 的 dev 上下文跟随「宿主 sb」

`CONFIG_EROFS_FS_PAGE_CACHE_SHARE` 开启且挂了 `-o domain_id=xxx` 时，
多个 EROFS 实例可以共享同一批 inode。实现要点：共享 inode 挂在一个
**kern_mount 出来的匿名 sb** 上：

```c
/* ishare.c:12 */
static struct vfsmount *erofs_ishare_mnt;      /* 匿名挂载，ishare.c:215 建立 */

/* ishare.c:49 —— 共享 inode 都 iget 在这个匿名 sb 上 */
si = iget5_locked(erofs_ishare_mnt->mnt_sb, ...);
```

而匿名 sb **没有** `s_bdev` / `devs` / `dif0`——那数据从哪读？读路径会先换 inode：

```c
/* ishare.c:176 erofs_real_inode() */
if (inode->i_sb != erofs_ishare_mnt->mnt_sb)
	return inode;                       /* 普通 inode：不动 */
/* 共享 inode：从 ishare_list 里抓一个真实实例的 inode */
list_for_each_entry(vi, &vi_share->ishare_list, ishare_list) {
	realinode = igrab(&vi->vfs_inode);  /* ★属于某个真实 erofs 实例 */
	...
}
```

随后 `erofs_iomap_begin()` 用的是 **realinode 的 sb**：

```c
/* data.c:289 erofs_iomap_begin() */
struct inode *realinode = ctx ? ctx->realinode : inode;
struct super_block *sb = realinode->i_sb;   /* data.c:295 ★宿主实例的 sb */
```

⇒ **`erofs_map_dev()`、`sb->s_bdev`、`devs`、`dif0` 全部取自宿主实例**：
同一个共享文件在不同挂载点读，实际 I/O 走的是"ishare_list 里抓到的那个实例"的设备。
这也是 `erofs_read_folio` / `erofs_readahead` / fileio 三处都先调
`erofs_real_inode()` 的原因（`data.c:401 / 419`、`fileio.c`）。

#### 4.11 DIO 的隐含条件：`inode->i_sb->s_bdev` 非 NULL

```c
/* data.c:451 erofs_file_read_iter() */
if ((iocb->ki_flags & IOCB_DIRECT) && inode->i_sb->s_bdev) {
	...
	return iomap_dio_rw(iocb, to, &erofs_iomap_ops, ...);
}
return filemap_read(iocb, to, 0);           /* ★回退缓冲读 */
```

⇒ **fileio 模式（`s_bdev == NULL`）没有 DIO**：`O_DIRECT` 打开不报错，
但静默退化成普通缓冲读。这解释了为什么 `statx` 的 DIOALIGN 在 fileio 模式
也一并不报（§6.2）——两者是同一套前提。

---

## 5. 三种典型场景的完整链路

#### 5.1 单设备（无 device table）

```
mount /dev/vdb
  → get_tree_bdev_flags() 设 sb->s_bdev = /dev/vdb
  → devs->extra_devices = 0, flatdev = false
  → erofs_scan_devices(): ondisk_extradevs = 0 ⇒ 直接 return 0（不建 idr 项）

读文件
  → erofs_map_blocks(): m_deviceid = 0, m_pa = 块地址
  → erofs_map_dev(): fill_from_devinfo(dif0) + m_bdev = sb->s_bdev；m_deviceid=0 且 extra_devices=0 ⇒ 不动
  → iomap->bdev = sb->s_bdev；addr = dif0.fsoff + m_pa
```

#### 5.2 flatdev（镜像声明了额外设备，但挂载时没给）

```
mkfs --blobdev=... （镜像 dsb->extra_devices = 1）
mount /dev/vdb            ← 忘了 -o device=
  → erofs_scan_devices(): ondisk=1, devs->extra_devices=0 ⇒ ★flatdev = true
  → device_id_mask = roundup_pow_of_two(1+1)-1 = 1
  → 走 else 分支：为每个 slot 建 dif（填 blocks/uniaddr），但 erofs_init_device() 里
    「!flatdev」不成立 ⇒ 不打开任何设备、dif->file = NULL
  → devs->extra_devices 变成 1

读一个落在 device 1 的 chunk
  → m_deviceid = 1
  → erofs_map_dev(): idr_find(device_id-1=0) 拿到 dif（有 uniaddr，无 file）
  → flatdev ⇒ m_pa += erofs_pos(dif->uniaddr)，★不换 m_dif/m_bdev
  → iomap->bdev 仍是 sb->s_bdev
```

⇒ 含义：内核**假设**所有额外设备的数据就拼接在主设备之后，于是"设备 1 的块 0"
= "主设备的块 uniaddr"。若实际不是这样，读到的就是错数据（这是挂载者的责任）。

#### 5.3 真多设备（`-o device=` 给足）

```
mkfs --blobdev=blob.img
mount -t erofs -o device=/dev/vdc /dev/vdb /mnt
  → Opt_device: dif->path="/dev/vdc" 入 idr(key 0)，extra_devices = 1
  → erofs_scan_devices(): ondisk=1 == given=1 ✓；flatdev 保持 false
  → device_id_mask = 1
  → idr_for_each_entry → erofs_init_device(): fs_bdev_file_open_by_path() 打开 /dev/vdc
                        → dif->file（块设备）→ dif->dax_dev（若支持）
                        → 填 blocks / uniaddr

读一个落在 device 1 的 chunk
  → m_deviceid = 1
  → erofs_map_dev(): idr_find(0) → dif → erofs_fill_from_devinfo(map, sb, dif)
        ⇒ m_dif = dif（device 1）
        ⇒ m_bdev = file_bdev(dif->file) = /dev/vdc 的 bdev ★
  → iomap->bdev = /dev/vdc；addr = dif->fsoff + m_pa
  → bio 也从 /dev/vdc 提交
```

---

## 6. 对外接口：statfs / statx / sysfs

#### 6.1 `statfs`：dev 影响两个字段（`super.c:1077`）

```c
buf->f_blocks = sbi->total_blocks;          /* 主 + 所有额外设备 */
buf->f_bfree = buf->f_bavail = 0;           /* 只读 fs，永远 0 */
...
if (uuid_is_null(&sb->s_uuid))
	buf->f_fsid = u64_to_fsid(!sb->s_bdev ? 0 :
			huge_encode_dev(sb->s_bdev->bd_dev));
```

| 字段 | 单设备 | 多设备 | fileio |
|---|---|---|---|
| `f_blocks` | `dif0.blocks` | `dif0.blocks + Σ dif->blocks` | 同左（按镜像声明的块数） |
| `f_fsid` | `huge_encode_dev(s_bdev->bd_dev)` | 同左（**只认主设备**） | `0`（`s_bdev == NULL`） |

⇒ `total_blocks` 的累加发生在 `super.c:178`（`sbi->total_blocks += dif->blocks;`），
初值 `sbi->total_blocks = sbi->dif0.blocks;`（`super.c:193`）。

#### 6.2 `statx` 的 DIO 对齐上报也依赖 `s_bdev`（`inode.c:319`）

```c
struct block_device *bdev = inode->i_sb->s_bdev;
...
if ((request_mask & STATX_DIOALIGN) && S_ISREG(inode->i_mode)) {
	stat->result_mask |= STATX_DIOALIGN;
	if (bdev && !compressed) {
		stat->dio_mem_align = bdev_dma_alignment(bdev) + 1;       /* 338 */
		stat->dio_offset_align = bdev_logical_block_size(bdev);   /* 339 */
	}
}
```

⇒ **fileio 模式（`s_bdev == NULL`）或压缩 inode 一律不报 DIO 对齐**，
内核注释也明说：`STATX_DIOALIGN is only supported in bdev-based mode and uncompressed inodes`。

#### 6.3 sysfs：只看得到「内核支不支持」，看不到「这个实例用没用」

```c
/* sysfs.c:92 */
EROFS_ATTR_FEATURE(device_table);
/* sysfs.c:106 */
ATTR_LIST(device_table),
```

导出为 `/sys/fs/erofs/features/device_table`，只读，`show` 恒返回 `"supported\n"`（`sysfs.c` 的 `attr_feature` 分支）。

⇒ **它反映的是 `CONFIG_EROFS_FS` 编译期能力，与某个挂载实例是否启用设备表无关**。
想知道实例有没有设备表，得看 `dmesg` 或 `dump.erofs -s` 的 `incompatible features`。

另外 `sbi->s_kobj`（`internal.h:136`）在 `erofs_register_sysfs()`（`sysfs.c`）里以
`sb->s_sysfs_name` 建目录 ⇒ `/sys/fs/erofs/<devname>/`，这才是**按设备实例**区分的路径。

---

## 7. 生命周期与清理

#### 7.1 正常卸载路径

```
umount
  → erofs_kill_sb()                       super.c:946
      ├─ dif0.file ? kill_anon_super(sb)  super.c:951   （fileio：匿名 sb）
      │            : kill_block_super(sb) super.c:953   （bdev：归还 s_bdev）
      ├─ erofs_drop_internal_inodes(sbi)  super.c:954   （packed/metabox/managed_cache）
      ├─ fs_put_dax(sbi->dif0.dax_dev, NULL)  super.c:955
      └─ erofs_sb_free(sbi, sb)           super.c:956
             ├─ erofs_free_dev_context(sbi->devs, sb)   super.c:886
             ├─ kfree_sensitive(sbi->domain_id)
             ├─ if (sbi->dif0.file) fput(sbi->dif0.file) super.c:888-889
             └─ kfree(sbi)
      └─ sb->s_fs_info = NULL             super.c:957
```

而 `erofs_put_super()`（`super.c:960`，由 `kill_***_super` 回调）**先于**上面的
`erofs_drop_internal_inodes / erofs_sb_free` 执行：

```c
static void erofs_put_super(struct super_block *sb)
{
	erofs_unregister_sysfs(sb);
	erofs_shrinker_unregister(sb);
	erofs_xattr_prefixes_cleanup(sb);
	erofs_drop_internal_inodes(sbi);
	erofs_free_dev_context(sbi->devs, sb);   /* ★第一次释放 */
	sbi->devs = NULL;                        /* ★置 NULL */
}
```

⇒ `erofs_free_dev_context()` **会被调到两次**（`put_super` 一次 + `erofs_sb_free` 一次）。
第二次安全，因为 `if (!devs) return;`（`super.c:877`）+ `devs` 已被置 NULL。

#### 7.2 单个设备的释放回调

```c
/* super.c:857 */
static int erofs_release_device_info(int id, void *ptr, void *data)
{
	struct super_block *sb = data;
	struct erofs_device_info *dif = ptr;

	fs_put_dax(dif->dax_dev, NULL);
	if (dif->file) {
		if (S_ISBLK(file_inode(dif->file)->i_mode))
			fs_bdev_file_release(dif->file, sb);  /* ★带 holder sb 释放 */
		else
			fput(dif->file);
		kfree(dif->path);
	}
	kfree(dif);
	return 0;
}

/* super.c:874 */
static void erofs_free_dev_context(struct erofs_dev_context *devs,
				   struct super_block *sb)
{
	if (!devs)
		return;
	idr_for_each(&devs->tree, &erofs_release_device_info, sb);
	idr_destroy(&devs->tree);
	kfree(devs);
}
```

⚠️ `kfree(dif->path)` 在 `if (dif->file)` **里面** ——
flatdev 建出来的 dif 没有 `file`，`path` 是 `kmemdup_nul(dis->tag)` 来的……但 flatdev 分支
`super.c:137` 的 `if (!sbi->devs->flatdev && !dif->path)` 也跳过了 tag 拷贝，
所以 flatdev 的 dif **path 也是 NULL**，不构成泄漏。逻辑自洽，但读起来很绕。

⇒ 只有**真正打开过**（非 flatdev）的设备才需要关闭；flatdev 建的 dif 只有内存数据。

#### 7.3 mount 失败早退路径

```c
/* super.c:894 */
static void erofs_fc_free(struct fs_context *fc)
{
	struct erofs_sb_info *sbi = fc->s_fs_info;

	/*
	 * Freed here only if an error occurs before the sb is set up; at that
	 * point no block-backed device has been claimed (that happens in
	 * fill_super), so the NULL sb never reaches fs_bdev_file_release().
	 */
	if (sbi)
		erofs_sb_free(sbi, NULL);
}
```

⇒ 传 `sb = NULL` 是**故意的**：此时还没进 `fill_super`，没有任何设备被 `fs_bdev_file_open_by_path()`
claim 过，所以 `erofs_release_device_info()` 里的 `fs_bdev_file_release(file, NULL)` 不会被调到。

#### 7.4 释放顺序小结

| 阶段 | 释放内容 | 关键函数 |
|---|---|---|
| 1 | sysfs / shrinker / xattr prefixes | `erofs_put_super()` `super.c:963-966` |
| 2 | 内部 inode（packed/metabox/managed_cache） | `erofs_drop_internal_inodes()` |
| 3 | **额外设备的 file/dax/path** | `erofs_free_dev_context()` `super.c:879` |
| 4 | 主设备（`s_bdev` 或 `dif0.file`） | `kill_block_super()` / `kill_anon_super()` |
| 5 | `dif0.dax_dev` | `fs_put_dax()` `super.c:955` |
| 6 | `dif0.file` / `domain_id` / `sbi` | `erofs_sb_free()` `super.c:884` |

---

## 8. 实测锚点（本机验证过的几个值）

| 场景 | 实测值 | 出处 |
|---|---|---|
| 带 `--blobdev` 的镜像 `extra_devices` | **1** | superblock 偏移 86（`od` 实测 `01 00`） |
| `devt_slotoff` | **9** ⇒ device table 在 `9 * 128 = 1152` | superblock 偏移 88 |
| chunk-based 文件的 `device_id` | **固定 1**（mkfs 只支持一个 blob 设备） | `erofs_map_chunks` VM 打印 `last = 0x1_0000_0000_0010` |
| `flatdev` | 未触发（我们给了 `-o device=`） | — |

（偏移 86/88 的来源见 §2.3 的结构累加复核。）

---

## 9. 源码核查全覆盖清单（逐文件）

对 `fs/erofs/` 下所有 `.c` 逐个核对「有没有 dev 相关代码」，确保没有漏网：

| 文件 | dev 相关点 | 详见 |
|---|---|---|
| `super.c` | 选项解析(415/519/554)、dif0 初始化(302/322/555/710)、扫描设备(183)、打开设备(125)、statfs(1077)、释放(857/874/884/894/946/960)、show_options(1116) | §3 §6.1 §7 |
| `data.c` | `init_metabuf`(54)、chunk device_id 解码(121)、`m_deviceid` 置位(139/159)、`fill_from_devinfo`(189)、**`erofs_map_dev` 三支路**(199)、iomap 用 dev(315-330)、DIO 需 `s_bdev`(451) | §4.2-4.5 §4.11 |
| `zdata.c` | 压缩 bio 绑定设备(1668-1735)：`bio_alloc(mdev.m_bdev)`(1726)、bi_sector 加 fsoff(1730)、**按设备拆 bio**(1693)、fileio 分支(1724) | §4.6 |
| `zmap.c` | 压缩 **FIEMAP/SEEK_HOLE 上报**硬编码 `sb->s_bdev`(805)；压缩读不经此文件 | §4.7 |
| `fileio.c` | `erofs_fileio_rq_alloc` 用 `mdev->m_dif->file`(72)、bi_sector 用 fsoff(141/212)、按 `m_deviceid` 拆请求(126)、**`erofs_read_meta_folio` 经 `erofs_map_dev`**(198-206) | §4.2 §4.8 |
| `inode.c` | `statx` DIOALIGN 用 `sb->s_bdev`(319)、`erofs_iget` 挂 aops(258-259) | §6.2 §4.2 |
| `ishare.c` | **`erofs_real_inode()`(176)**：ishare 匿名 sb 上的 inode 读数据时换成真实实例的 inode ⇒ dev 上下文跟随宿主 sb | §4.10 |
| `sysfs.c` | `device_table` feature 导出(92/106)、`s_kobj` 按实例建目录 | §6.3 |
| `internal.h` | 三个结构定义(44/66/371)、`dif0`/`devs`/`total_blocks`/`device_id_mask`(84/102/103/114)、`erofs_is_fileio_mode`(158) | §1 |
| `erofs_fs.h` | `erofs_deviceslot`(43,128B)、`extra_devices`(79)、`devt_slotoff`(80)、`rb.blocks_hi`(63) | §2 |
| `dir.c` | 无 | — |
| `namei.c` | 无 | — |
| `xattr.c` | 无（xattr 走经典元数据，bdev 模式恒在主设备） | §4.2 |
| `decompressor*.c` | 无（纯解压，不碰设备） | — |
| `zutil.c` | 无 | — |

⇒ **dev 逻辑集中在 4 个文件**：`super.c`（初始化/释放）、`data.c`（映射 + 非压缩 iomap）、`zdata.c`（压缩 I/O bio）、`fileio.c`（文件后端）。
  `zmap.c` 只在 FIEMAP/SEEK_HOLE 上报时碰一下 `s_bdev`，压缩读路径不经过它。
其余文件完全不感知设备。

---

## 10. 关键代码引用总表

| 环节 | 位置 |
|---|---|
| **mount / 初始化** | |
| `sb->s_bdev` 设置（VFS） | `super.c:787 erofs_fc_get_tree()` → `get_tree_bdev_flags()`（803） |
| `sbi->devs` 创建 + idr/rwsem 初始化 | `super.c:914 erofs_init_fs_context()`（922 / 929 / 930） |
| `-o device=` 解析（只存路径） | `super.c:519 case Opt_device`（kstrdup 523、计数 536） |
| `-o fsoffset=` 解析 / 校验 / 回显 | `super.c:555 / 727 / 1116` |
| `dif0.blocks`（含 48bit 高位）/ `packed_nid` | `super.c:302 / 322 / 327` |
| `dif0.dax_dev` | `super.c:710` |
| `dif0.file` 来源（fd 参数 / ENOTBLK 回退） | `super.c:467 / 826` |
| `erofs_is_fileio_mode()` | `internal.h:158` |
| remount 忽略 `device=` | `super.c:835 erofs_fc_reconfigure()` |
| 设备扫描 / `flatdev` / `device_id_mask` | `super.c:183 erofs_scan_devices()`（199 / 210 / 213 / 216 / 217） |
| 打开单个设备 + 填 blocks/uniaddr | `super.c:125 erofs_init_device()`（148 / 159 / 174 / 176 / 178） |
| DAX 不支持时降级 | `super.c:206（主）/ 165（额外）/ 731（块大小）` |
| **on-disk** | |
| 设备表项（128 B） | `erofs_fs.h:43 struct erofs_deviceslot`，`erofs_fs.h:51 EROFS_DEVT_SLOT_SIZE` |
| superblock 的 `extra_devices` / `devt_slotoff` | `erofs_fs.h:79 / 80`（文件偏移 86 / 88） |
| **访问路径** | |
| aops 选择 | `internal.h:442 erofs_get_aops()` |
| 元数据 mapping 三选一 | `data.c:54 erofs_init_metabuf()`（`data.c:70`） |
| managed_cache 页回填（经 map_dev） | `data.c:42`、`fileio.c:198 erofs_read_meta_folio()` |
| metabox inode 建立 | `super.c:762`，aops 挂载 `inode.c:259` |
| **统一地址 → 具体设备** | `data.c:199 erofs_map_dev()`（支路①208 / ②215 / ③222-236） |
| **`m_bdev` 赋值（主设备 / 额外设备）** | `data.c:189 erofs_fill_from_devinfo()` + `data.c:207` |
| iomap 用 `m_bdev` / `dax_dev` | `data.c:315-330` |
| 压缩路径 `bio_alloc(m_bdev)` | `zdata.c:1641 z_erofs_submit_queue()`（1685 / 1693 / 1724 / 1726 / 1730） |
| 压缩 FIEMAP/SEEK_HOLE 上报硬编码 `s_bdev` | `zmap.c:793 z_erofs_iomap_begin_report()`（805），ops 836；使用者 `data.c:386 / 510` |
| fileio 用 `m_dif->file` | `fileio.c:66 / 72 / 141 / 212`，按 deviceid 拆请求 126 |
| chunk `device_id` 解码 + `addrmask` | `data.c:95 / 121`，`m_deviceid` 置位 139 / 159 |
| ishare 换 realinode | `ishare.c:176 erofs_real_inode()`，`data.c:295` |
| DIO 需 `s_bdev` | `data.c:451` |
| **对外接口** | |
| `statfs` 用 `total_blocks` / `s_bdev->bd_dev` | `super.c:1083 / 1089-1091` |
| `statx` DIOALIGN 用 `s_bdev` | `inode.c:319 / 338-339` |
| sysfs `device_table` 导出 | `sysfs.c:92 / 106` |
| **释放** | |
| 单设备释放回调 | `super.c:857 erofs_release_device_info()` |
| 释放链 | `super.c:874 / 884 / 894 / 946 / 960` |
| **结构体定义** | |
| `erofs_device_info` / `erofs_dev_context` / `erofs_map_dev` | `internal.h:44 / 66 / 371` |
| 条件编译桩（fileio） | `internal.h:397-400 / 506-511` |

---

## 参考
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)  
[erofs-utils(1.9.4)](https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git)  
[linux-stable (93f51579e7df)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  