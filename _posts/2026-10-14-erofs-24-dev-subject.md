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

- `tree` 是 **idr**：key = `device_id - 1`（所以 `device_id=1` 存在 key 0）。
- `rwsem` 保护 `tree` 的并发访问（读路径 down_read，`-o device=` 解析时 down_write）。

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

主设备也用这个结构表示：**`sbi->dif0`**（`EROFS_SB(sb)->dif0`）。

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

#### 1.4 关系图

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

---

## 2. mount 初始化：每一步

#### 2.1 `sb->s_bdev` 从哪来

```c
/* super.c:797 erofs_fc_get_tree() */
ret = get_tree_bdev_flags(fc, erofs_fc_fill_super, ...);
```

`get_tree_bdev_flags()` 是 VFS 提供的通用实现：解析 `fc->source`（如 `/dev/vdb`）→ 打开块设备 →
**设置 `sb->s_bdev`** → 再回调 `erofs_fc_fill_super()`。

⇒ EROFS 自己**不打开主设备**，主设备由 VFS 搞定，`sb->s_bdev` 就是它。
（file-backed 挂载时 `sb->s_bdev == NULL`，走另一条路，见 §2.4。）

#### 2.2 `sbi->devs` 的创建

```c
/* super.c:922 erofs_fc_fill_super() */
sbi->devs = kzalloc_obj(struct erofs_dev_context);
if (!sbi->devs) { ... }
fc->s_fs_info = sbi;

idr_init(&sbi->devs->tree);          /* super.c:929 */
init_rwsem(&sbi->devs->rwsem);       /* super.c:930 */
```

此时 `extra_devices = 0`、`flatdev = false`（kzalloc 清零）。

#### 2.3 解析 `-o device=`（只记路径，不打开）

```c
/* super.c:519  case Opt_device: */
dif = kzalloc_obj(*dif);
dif->path = kstrdup(param->string, GFP_KERNEL);          /* ★只保存路径字符串 */
down_write(&sbi->devs->rwsem);
ret = idr_alloc(&sbi->devs->tree, dif, 0, 0, GFP_KERNEL); /* 分配 id（key） */
up_write(&sbi->devs->rwsem);
...
++sbi->devs->extra_devices;                                /* ★计数 +1 */
```

关键：**这一步不打开设备**，只是把路径按"出现顺序"放进 idr。
所以 `-o device=A,device=B` ⇒ A 是 `device_id=1`、B 是 `device_id=2`（顺序必须对应镜像里的 device table）。

#### 2.4 `dif0`（主设备的 device_info）填什么

```c
/* super.c:302 erofs_read_superblock() */
sbi->dif0.blocks = le32_to_cpu(dsb->blocks_lo);
/* 48bit 时补高位：super.c:322 */
sbi->dif0.blocks |= ((u64)le16_to_cpu(dsb->rb.blocks_hi) << 32);
sbi->packed_nid = le64_to_cpu(dsb->packed_nid);
```

```c
/* super.c:710 erofs_fc_fill_super() —— 块设备挂载分支 */
sbi->dif0.dax_dev = fs_dax_get_by_bdev(sb->s_bdev,
                &sbi->dif0.dax_part_off, NULL, NULL);
```

⇒ `dif0` **没有 `file`/`path`**：主设备由 `sb->s_bdev` 直接表达。
（file-backed 挂载时反过来：`sbi->dif0.file` 由 `fc->source` 打开，`sb->s_bdev == NULL`。）

#### 2.5 `erofs_scan_devices()`：读 device table（`super.c:183`）

```c
sbi->total_blocks = sbi->dif0.blocks;                 /* 先算主设备的块数 */
ondisk_extradevs = erofs_sb_has_device_table(sbi) ? le16_to_cpu(dsb->extra_devices) : 0;

/* ① 数量必须一致（super.c:199） */
if (sbi->devs->extra_devices && ondisk_extradevs != sbi->devs->extra_devices) {
        erofs_err(sb, "extra devices don't match (ondisk %u, given %u)", ...);
        return -EINVAL;
}
if (!ondisk_extradevs) return 0;                       /* 没有额外设备，直接返回 */

/* ② flatdev 的判定（super.c:213） */
if (!sbi->devs->extra_devices)
        sbi->devs->flatdev = true;                     /* ★声明了但没给 ⇒ 扁平 */

/* ③ device_id 掩码（super.c:216） */
sbi->device_id_mask = roundup_pow_of_two(ondisk_extradevs + 1) - 1;

/* ④ 逐个初始化 */
pos = le16_to_cpu(dsb->devt_slotoff) * EROFS_DEVT_SLOT_SIZE;   /* device table 起点 */
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

**`flatdev` 的三态含义**

| 镜像 `extra_devices` | 挂载给 `-o device=` | 结果 |
|---|---|---|
| 0 | 无 | 单设备，`flatdev=false` |
| >0 | 给了 N 个（N 必须相等） | 真多设备，`flatdev=false` |
| >0 | **一个都没给** | **`flatdev=true`**：假设所有设备在**主设备之后连续拼接**，不打开任何新设备 |

#### 2.6 `erofs_init_device()`：打开设备 / 填 `blocks` `uniaddr`（`super.c:125`）

```c
dis = erofs_read_metabuf(buf, sb, *pos, false);        /* 读一个 erofs_deviceslot（128 B） */

/* ① 路径：没给 -o device= 时从 tag 里取 */
if (!sbi->devs->flatdev && !dif->path) {
        if (!dis->tag[0]) { erofs_err("empty device tag"); return -EINVAL; }
        dif->path = kmemdup_nul(dis->tag, sizeof(dis->tag), GFP_KERNEL);
}

/* ② 打开设备：★flatdev 时跳过（不打开任何东西） */
if (!sbi->devs->flatdev) {
        file = erofs_is_fileio_mode(sbi) ?
                        filp_open(dif->path, O_RDONLY|O_LARGEFILE, 0) :      /* 文件后端 */
                        fs_bdev_file_open_by_path(dif->path, BLK_OPEN_READ, sb->s_type, sb);
        if (IS_ERR(file)) { ... }
        if (!erofs_is_fileio_mode(sbi))
                dif->dax_dev = fs_dax_get_by_bdev(file_bdev(file), &dif->dax_part_off, NULL, NULL);
        else if (!S_ISREG(file_inode(file)->i_mode)) { fput(file); return -EINVAL; }
        if (!dif->dax_dev && test_opt(&sbi->opt, DAX_ALWAYS)) { ...关闭 DAX... }
        dif->file = file;
}

/* ③ 无条件填：块数与统一起始地址（48bit 时拼高位） */
_48bit = erofs_sb_has_48bit(sbi);
dif->blocks  = le32_to_cpu(dis->blocks_lo)  | (_48bit ? (u64)le16_to_cpu(dis->blocks_hi)  << 32 : 0);
dif->uniaddr = le32_to_cpu(dis->uniaddr_lo) | (_48bit ? (u64)le16_to_cpu(dis->uniaddr_hi) << 32 : 0);
sbi->total_blocks += dif->blocks;
*pos += EROFS_DEVT_SLOT_SIZE;                          /* 下一个 slot */
```

⇒ **即使是 `flatdev`，`blocks` / `uniaddr` 也会被填上**——因为扁平模式要靠 `uniaddr` 做地址平移。

---

## 3. 文件访问：`dev` 怎么被用

#### 3.1 元数据读取：永远走主设备（或 managed_cache / metabox）

```c
/* data.c:55 erofs_init_metabuf() */
if (in_metabox) {
        buf->mapping = sbi->metabox_inode->i_mapping;      /* 元数据压缩 */
        return 0;
}
if (erofs_is_fileio_mode(sbi)) {
        buf->mapping = sbi->managed_cache->i_mapping;      /* 文件后端：托管缓存 */
        buf->mc = true;
} else {
        buf->off = sbi->dif0.fsoff;
        buf->mapping = sb->s_bdev->bd_mapping;             /* ★普通块设备：主设备的 mapping */
}
```

⇒ **元数据永远从主设备读**（`sb->s_bdev`），与 `map->m_bdev` 无关——
元数据（inode / dirent / xattr / 各类索引）不会被分到额外设备。

#### 3.2 `erofs_map_dev()`：统一地址 → 具体设备（`data.c:197`）

```c
int erofs_map_dev(struct super_block *sb, struct erofs_map_dev *map)
{
        struct erofs_dev_context *devs = EROFS_SB(sb)->devs;
        ...
        /* ① 默认填主设备 */
        erofs_fill_from_devinfo(map, sb, &EROFS_SB(sb)->dif0);
        map->m_bdev = sb->s_bdev;       /* ★use s_bdev for the primary device */

        if (map->m_deviceid) {                                    /* ② 非主设备 */
                down_read(&devs->rwsem);
                dif = idr_find(&devs->tree, map->m_deviceid - 1); /* device_id → dif */
                if (!dif) { up_read; return -ENODEV; }
                if (devs->flatdev) {                              /* ★扁平：只平移地址 */
                        map->m_pa += erofs_pos(sb, dif->uniaddr);
                        up_read(&devs->rwsem);
                        return 0;                                  /* 不换 dif / bdev */
                }
                erofs_fill_from_devinfo(map, sb, dif);             /* 切到该设备 */
                up_read(&devs->rwsem);
        } else if (devs->extra_devices && !devs->flatdev) {         /* ③ 按区间反查设备 */
                down_read(&devs->rwsem);
                idr_for_each_entry(&devs->tree, dif, id) {
                        if (!dif->uniaddr) continue;
                        startoff = erofs_pos(sb, dif->uniaddr);
                        if (map->m_pa >= startoff &&
                            map->m_pa < startoff + erofs_pos(sb, dif->blocks)) {
                                map->m_pa -= startoff;             /* → 设备内偏移 */
                                erofs_fill_from_devinfo(map, sb, dif);
                                break;
                        }
                }
                up_read(&devs->rwsem);
        }
        return 0;
}
```

`erofs_fill_from_devinfo()`（**`data.c:187`**，本文最关键的一小段）：

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
- 主设备：`map->m_bdev = sb->s_bdev`（`data.c:207` 显式赋值，覆盖 `fill_from_devinfo` 里的 NULL）
- 额外设备：`fill_from_devinfo` 里 `file_bdev(dif->file)`（前提是该设备的 file 是块设备）

#### 3.3 非压缩数据读：iomap 用 `m_bdev`

```c
/* data.c:315 erofs_iomap_begin() —— 仅数据（非 EROFS_MAP_META） */
mdev = (struct erofs_map_dev) { .m_deviceid = map.m_deviceid, .m_pa = map.m_pa };
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

#### 3.4 压缩数据读：`bio_alloc(mdev.m_bdev)`

```c
/* zdata.c:1685 z_erofs_submit_bio / 提交循环 */
(void)erofs_map_dev(sb, &mdev);
cur = mdev.m_pa;
...
/* ① bio 需要拆分的两个条件：物理不连续 或 设备变了 */
if (bio && (cur != last_pa || bio->bi_bdev != mdev.m_bdev)) {
        if (erofs_is_fileio_mode(EROFS_SB(sb))) erofs_fileio_submit_bio(bio);
        else submit_bio(bio);
        bio = NULL;
}
...
/* ② 分配 bio 时绑定设备 */
if (!bio) {
        if (erofs_is_fileio_mode(EROFS_SB(sb)))
                bio = erofs_fileio_bio_alloc(&mdev);
        else
                bio = bio_alloc(mdev.m_bdev, BIO_MAX_VECS, REQ_OP_READ, GFP_NOIO);  /* ★ */
        bio->bi_end_io = z_erofs_endio;
        bio->bi_iter.bi_sector = (mdev.m_dif->fsoff + cur) >> 9;   /* 扇区 = 字节/512 */
        ...
}
```

⇒ `bi_bdev != mdev.m_bdev` 这个判断很关键：**同一个 bio 不能跨设备**，
遇到不同设备（或地址不连续）就必须先提交、再开新 bio。

#### 3.5 fileio（文件后端）：用 `m_dif->file`，没有 bdev

```c
/* fileio.c:66 erofs_fileio_rq_alloc() */
bio_init(&rq->bio, NULL, rq->bvecs, ARRAY_SIZE(rq->bvecs), REQ_OP_READ);  /* bdev=NULL */
rq->iocb.ki_filp = mdev->m_dif->file;      /* ★用文件指针做 VFS 读 */
rq->sb = mdev->m_sb;
```

```c
/* fileio.c:212 —— 计算文件内的字节偏移 */
(io.dev.m_dif->fsoff + io.dev.m_pa) >> 9;
```

⇒ fileio 模式下 `map->m_bdev` 是 NULL（因为 `fill_from_devinfo` 只在 `S_ISBLK` 时设 bdev），
数据走 `vfs_iocb_iter_read()`。

#### 3.6 chunk-based 文件：`m_deviceid` 从哪来

chunk 索引项把 **`device_id` 编在块地址的 bit48 以上**（见 `erofs_map_chunks` 专题），
`erofs_map_dev()` 收到 `m_deviceid` 后按 §3.2 的第 ② 支路处理：

```
chunk index 里的 device_id ──► map->m_deviceid ──► erofs_map_dev()
                                                    ├─ flatdev → m_pa += uniaddr（不换设备）
                                                    └─ 否则   → idr_find → 换 m_dif / m_bdev
```

⇒ 这是"数据真正落在另一台设备上"的**唯一入口**。

---

## 4. 三种典型场景的完整链路

#### 4.1 单设备（无 device table）

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

#### 4.2 flatdev（镜像声明了额外设备，但挂载时没给）

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

#### 4.3 真多设备（`-o device=` 给足）

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

## 5. 生命周期与清理

```c
/* super.c:879 erofs_free_dev_context() */
idr_for_each(&devs->tree, &erofs_release_device_info, sb);   /* 逐个释放 */
idr_destroy(&devs->tree);
```

`erofs_release_device_info()`：
- `fs_bdev_file_release(dif->file, sb)`（`super.c:865`）关闭打开的设备文件
- 释放 `dif->path`
- 释放 `dif` 本身

⇒ 只有**真正打开过**（非 flatdev）的设备才需要关闭；flatdev 建的 dif 只有内存数据。

---

## 6. 实测锚点（本机验证过的几个值）

| 场景 | 实测值 | 出处 |
|---|---|---|
| 带 `--blobdev` 的镜像 `extra_devices` | **1** | superblock 偏移 86（`od` 实测 `01 00`） |
| `devt_slotoff` | **9** ⇒ device table 在 `9 * 128 = 1152` | superblock 偏移 88 |
| chunk-based 文件的 `device_id` | **固定 1**（mkfs 只支持一个 blob 设备） | `erofs_map_chunks` VM 打印 `last = 0x1_0000_0000_0010` |
| `flatdev` | 未触发（我们给了 `-o device=`） | — |

---

## 7. 关键代码引用

| 环节 | 位置 |
|---|---|
| `sb->s_bdev` 设置（VFS） | `super.c:797 erofs_fc_get_tree()` → `get_tree_bdev_flags()` |
| `sbi->devs` 创建 + idr/rwsem 初始化 | `super.c:922 / 929 / 930` |
| `-o device=` 解析（只存路径） | `super.c:519 case Opt_device` |
| `dif0.blocks` / `packed_nid` | `super.c:302 / 322 / 327` |
| `dif0.dax_dev` | `super.c:710` |
| 设备扫描 / `flatdev` / `device_id_mask` | `super.c:183 erofs_scan_devices()`（含 199/213/216 三处判定） |
| 打开单个设备 + 填 blocks/uniaddr | `super.c:125 erofs_init_device()` |
| 释放 | `super.c:879 erofs_free_dev_context()`、`super.c:865 fs_bdev_file_release()` |
| **统一地址 → 具体设备** | `data.c:197 erofs_map_dev()` |
| **`m_bdev` 赋值（主设备 / 额外设备）** | `data.c:187 erofs_fill_from_devinfo()` + `data.c:207` |
| 元数据 mapping（主设备） | `data.c:55 erofs_init_metabuf()`（`data.c:71`） |
| iomap 用 `m_bdev` / `dax_dev` | `data.c:315–330` |
| 压缩路径 `bio_alloc(m_bdev)` | `zdata.c:1693 / 1726` |
| fileio 用 `m_dif->file` | `fileio.c:66 / 72 / 212` |
| 结构体定义 | `internal.h:44`（`erofs_device_info`）、`66`（`erofs_dev_context`）、`371`（`erofs_map_dev`） |
| on-disk device table 项 | `erofs_fs.h: struct erofs_deviceslot`（128 B，含 `tag[64]` / `blocks` / `uniaddr`） |


## 参考
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)  
[erofs-utils(1.9.4)](https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git)  
[linux-stable (93f51579e7df)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  