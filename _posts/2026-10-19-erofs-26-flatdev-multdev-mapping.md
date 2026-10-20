---
layout:     post
title:      EROFS flatdev and multidev mapping
subtitle:   EROFS 扁平块设备与多设备地址映射
date:       2026-10-19
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
---

# 26 · EROFS flatdev：多设备镜像的扁平块设备

> 源码依据：`/home/linux/erofs/linux-stable`（`v7.3-rc7` 之后的 master），  
> 用户态对照：`/home/linux/erofs/erofs-utils`（1.9.4）  
> 本文按**文件名 + 函数名/字段名**定位，不绑定行号——树会随上游推进，行号会漂。

---

## 一、结论先行

`flatdev` 是 `struct erofs_dev_context` 上的一个 `bool`，语义是：

> **镜像里声明了好几个设备，但这些设备的内容全都被摊平（flatten）到了同一块设备上。**

它不是 on-disk 格式字段，也不是挂载选项，而是**挂载时推断出来的运行态标志**。
一旦置位，内核做两件事：

1. **不解析 device slot 的 tag、不 open 任何设备文件**（`erofs_init_device()` 里的两道守卫）
2. **把 device table 的每个 slot 当成主设备地址空间里的一段区间**，用 `uniaddr` 做地址平移

代价是必须整体挂一个大设备；收益是不用再管理 N 个设备文件。

⚠️ 内核**不做任何一致性校验**：它只按地址平移，假定数据确实都在主设备里。
若实际不是，读出来的就是错位数据或 I/O 错误。

---

## 二、相关数据结构

```c
/* fs/erofs/internal.h —— struct erofs_device_info */
struct erofs_device_info {
	char *path;              /* 设备路径：来自 -o device= 或 slot tag */
	struct file *file;       /* open 得到的 file；flatdev 下恒为 NULL */
	struct dax_device *dax_dev;
	u64 fsoff, dax_part_off; /* 只有 dif0.fsoff 会被 -o fsoffset= 写入 */
	erofs_blk_t blocks;      /* 本设备总块数 */
	erofs_blk_t uniaddr;     /* ★ 统一地址空间里的起始块号 */
};

/* fs/erofs/internal.h —— 整个设备集合，不是单个设备 */
struct erofs_dev_context {
	struct idr tree;             /* 额外设备（不含 dif0） */
	struct rw_semaphore rwsem;
	unsigned int extra_devices;  /* -o device= 给了几个 */
	bool flatdev;                /* ★ 本文主角 */
};

/* fs/erofs/internal.h —— erofs_map_dev() 的输入输出 */
struct erofs_map_dev {
	struct super_block *m_sb;
	struct erofs_device_info *m_dif;  /* ★ 决定 fsoff / file / dax_dev */
	struct block_device *m_bdev;      /* 可能为 NULL */
	erofs_off_t m_pa;                 /* 设备内偏移（字节） */
	unsigned int m_deviceid;
};
```

⚠️ `flatdev` 挂在 **dev_context**（整个设备集合）上，不在 `device_info`（单个设备）上。
它是集合的**全局性质**，不是某个设备的属性——这个区别正是理解它的关键。

对应的 on-disk 结构：

```c
/* fs/erofs/erofs_fs.h —— struct erofs_deviceslot */
struct erofs_deviceslot {
	u8 tag[64];        /* digest(sha256), etc. —— 注释写的不是 path */
	__le32 blocks_lo;  /* total blocks count of this device */
	__le32 uniaddr_lo; /* unified starting block of this device */
	__le16 blocks_hi;
	__le16 uniaddr_hi;
	u8 reserved[52];
};
```

`uniaddr` = *unified starting block*：把所有设备首尾相接连成一条线性地址空间后，
**本设备在其中的起始块号**。

#### 2.1 device table 怎么定位：`devt_slotoff`

device table 不在固定位置，靠 superblock 里的两个字段找到它：

```c
/* fs/erofs/erofs_fs.h —— struct erofs_super_block */
__le16 extra_devices;   /* # of devices besides the primary device */
__le16 devt_slotoff;    /* startoff = devt_slotoff * devt_slotsize */
```

- `extra_devices`：额外设备的数量，**不含主设备**
- `devt_slotoff`：device table 的起始位置，**单位是 slot，不是块**

内核换算：

```c
/* erofs_scan_devices() */
pos = le16_to_cpu(dsb->devt_slotoff) * EROFS_DEVT_SLOT_SIZE;
```

其中 `EROFS_DEVT_SLOT_SIZE = sizeof(struct erofs_deviceslot)` = **128 字节**（erofs_fs.h:51）。
mkfs 写入时反向计算：

```c
/* erofs-utils/lib/super.c —— erofs_mkfs_init_devices() */
sbi->devt_slotoff = erofs_btell(bh, false) / EROFS_DEVT_SLOT_SIZE;
```

**为什么用 slot 而不是块地址**：`devt_slotoff` 是 16 位。按字节计只能表示 64 KiB；
按 128 字节的 slot 计则可表示约 8 MiB，**寻址范围扩大 128 倍**。
这一点与同结构里的 `meta_blkaddr` / `xattr_blkaddr`（都是**块号**）不同，容易混淆。

实测三个镜像：

| 镜像 | extra_devices | devt_slotoff | 字节偏移 |
|---|---|---|---|
| `multidev/main.erofs` | 1 | 9 | 1152 |
| `tmp-chunk8/md.erofs` | 1 | 9 | 1152 |
| `metabox-test/mb.erofs` | 0 | 0 | —（无 device table） |

**为什么通常是 9**：`EROFS_SUPER_OFFSET` = 1024 = 8 × 128，superblock 自身 128 字节
（`sb_extslots` = 0 时），device table 紧随其后 ⇒ 第 9 个 slot ⇒ 1152 字节。

`sb_extslots` > 0 时该值会后移。对照实测（同一源目录 + `--blobdev`，唯一变量是 `-m 4096`）：

| 镜像 | sb_extslots | sb_size | devt_slotoff | 字节 | superblock 结束 |
|---|---|---|---|---|---|
| `a.erofs`（无 metabox） | 0 | 128 | **9** | 1152 | 1152 |
| `b.erofs`（`-m 4096`） | 1 | 144 | **10** | 1280 | 1168 |

⇒ 规律是 `devt_slotoff` = ceil((1024 + `sb_size`) / 128)：

- 1024 + 128 = 1152，1152 / 128 = 9 ⇒ 9
- 1024 + 144 = 1168，1168 / 128 = 9.125 ⇒ 向上取整得 **10**

即 device table 起始位置会**向上对齐到下一个 128 字节 slot 边界**，
所以 `sb_extslots` 每多 1（superblock 增 16 字节）并不总是让 `devt_slotoff` 加 1，
只有跨过 slot 边界时才会。

⚠️ `extra_devices` = 0 时 `devt_slotoff` **不参与计算**——`erofs_scan_devices()`
先检查 `erofs_sb_has_device_table()` 与 `dsb->extra_devices`，为 0 就直接返回，
根本不会去读 device table。上表里 `mb.erofs` 的 0 属于"字段无意义"，
不是"device table 在偏移 0"。

---

## 三、flatdev 的唯一判定点

`erofs_scan_devices()`（`fs/erofs/super.c`）里只有一处赋值：

```c
if (!ondisk_extradevs)
        return 0;                          /* 镜像根本没有 device table → 提前返回 */

if (!sbi->devs->extra_devices)
        sbi->devs->flatdev = true;         /* ★ 唯一置位点 */
```

三个条件同时成立才置位：

| # | 条件 | 出处 |
|---|---|---|
| 1 | 镜像带 device table（`EROFS_FEATURE_INCOMPAT_DEVICE_TABLE`，incompat 0x8） | `fs/erofs/erofs_fs.h` |
| 2 | 磁盘上 `dsb->extra_devices > 0` | `erofs_scan_devices()` |
| 3 | **挂载时一个 `-o device=` 都没给** ⇒ `devs->extra_devices == 0` | `erofs_fc_parse_param()` 的 `Opt_device` |

第 3 条能成立，是因为前面的数量一致性检查被刻意绕开了：

```c
/* erofs_scan_devices() */
if (sbi->devs->extra_devices &&              /* ← 为 0 时整个 if 不成立 */
    ondisk_extradevs != sbi->devs->extra_devices) {
        erofs_err(sb, "extra devices don't match (ondisk %u, given %u)", ...);
        return -EINVAL;
}
```

也就是说「磁盘说有 N 个、你一个都没给」**不是错误，而是 flatdev 的入口**；
只有「给了但数量对不上」才报 `-EINVAL`。

#### 置位后的两处跳过

```c
/* erofs_init_device() */
if (!sbi->devs->flatdev && !dif->path) {      /* 守卫①：不读 tag */
        if (!dis->tag[0]) {
                erofs_err(sb, "empty device tag @ pos %llu", *pos);
                return -EINVAL;
        }
        dif->path = kmemdup_nul(dis->tag, sizeof(dis->tag), GFP_KERNEL);
}

if (!sbi->devs->flatdev) {                    /* 守卫②：不 open 设备 */
        file = erofs_is_fileio_mode(sbi) ?
                        filp_open(dif->path, O_RDONLY | O_LARGEFILE, 0) :
                        fs_bdev_file_open_by_path(dif->path, ...);
        dif->dax_dev = fs_dax_get_by_bdev(...);
        dif->file = file;
}
```

⇒ flatdev 下 `dif->file` **恒为 NULL**（`dif` 由 `kzalloc` 分配），`dif->path` 也不解析。
守卫①里还有 `!dif->path`：若 `-o device=` 已给路径，本就不必读 tag。

`blocks` / `uniaddr` 两个字段在守卫**之外**，所以 flatdev 下照常从 slot 读出来。

顺带：守卫②里也跳过了 `fs_dax_get_by_bdev()`，因此 flatdev 下额外设备的 `dax_dev`
同为 NULL。但 A1 分支用的是 `dif0.dax_dev`，所以 **flatdev 能否用 DAX 完全取决于主设备**，
与这些 slot 无关。

#### 3.1 tag 字段：从「设备标识」到实际上的死字段

`erofs_deviceslot.tag[64]` 的注释写的是 `digest(sha256), etc.`，但它在内核里**没有任何摘要运算**。
这个字段的历史正好解释了守卫①为什么长成现在这样。

**设计初衷（2021）**——`dfeab2e95a75`（Gao Xiang）*erofs: add multiple device support*：

> In the future, a dedicated device manager could be introduced then thus extra devices
> can be automatically scanned by UUID as well.

⇒ tag 是为「**按 UUID 自动发现/匹配额外设备**」预留的标识位。64 字节的容量刚好：
sha256 摘要 32 字节，hex 编码后 64 字符；UUID hex 是 32 字符。

**一次短暂的实现（2022）**——`ba73eadd23d1`（Jeffle Xu）*erofs: scan devices from device table*：

> When "-o device" mount option is not specified, scan the device table and instantiate
> the devices if there's any in the device table. In this case, **the tag field of each
> device slot uniquely specifies a device**.

这一版就是今天守卫①里的 `dif->path = kmemdup_nul(dis->tag, ...)` ——**tag 被当作设备路径**，
随后 `filp_open()` / `fs_bdev_file_open_by_path()` 打开它。此时 tag 是真的有用。

**被 flatdev 短路（2023）**——`8b465fecc35a` 引入 flatdev 后，不给 `-o device=` 时
`erofs_scan_devices()` 直接把 `flatdev` 置真，于是守卫①整体不成立，tag 不再被读。
紧接着 `f939aeea7ab7`（Jingbo Xu）*erofs: allow empty device tags in flatdev mode* 说明：

> Device tags aren't actually required in flatdev mode, thus fix mount failure due to
> empty device tags in flatdev mode.

**为什么必须允许空 tag**：`mkfs.erofs --blobdev=X` 走的是
`erofs_mkfs_init_devices()` → `calloc()` 分配 `sbi->devs`，**全程没有给 tag 赋值**，
写盘时 `memcpy(dis.tag, sbi->devs[i].tag, 64)` 写进去的就是 64 个 0。

实测（`/sdd/erofs/multidev/main.erofs`，`extra_devices=1`、`devt_slotoff=9`）：

```text
slot 字节偏移 = 9 × 128 = 1152
00 00 00 00 ... （前 64 字节全零 = tag 为空）
00 04 00 00   blocks_lo   = 0x400 = 1024 块（4 MiB 的 blob.img）
03 00 00 00   uniaddr_lo  = 3（主设备 12 KiB = 3 块）
```

**结论：在当前内核里 tag 的两条读取路径都不可达。**

| 挂载方式 | extra_devices | flatdev | 守卫① | tag 是否被读 |
|---|---|---|---|---|
| 给了 `-o device=` | != 0 | false | `!dif->path` 为假 | 否（路径已由参数给出） |
| 没给 | 0 | **true** | 整体为假 | 否（flatdev 短路） |

所以 `dif->path = kmemdup_nul(dis->tag, ...)` 与 `-EINVAL "empty device tag"` 这两行
实际上执行不到。tag 退化为**纯磁盘元数据**，仍有使用者的地方在用户态：

- `erofs-utils/lib/vmdk.c` 生成 VMDK 描述文件时，
  `const char *name = sbi->devs[i].src_path ?: (const char *)sbi->devs[i].tag;`
  —— `src_path` 优先，tag 兜底，作为 extent 的文件名。
- rebuild 路径（`mkfs/main.c`）在源镜像有 tag 时继承，否则用
  `erofs_uuid_unparse_as_tag()` 把源镜像 UUID 转成 32 个 hex 字符填进去。

一句话：**tag 是「设备槽位的名字」**，本意是让内核在不依赖挂载参数时识别槽位对应哪个物理设备；
flatdev 特性引入后内核不再用它，它只对镜像打包/重组/虚拟磁盘生成这类用户态工具还有意义。

#### 3.2 「恒不可达」的形式化论证

「两条路径都不可达」可以更严格地证明为「**对任何镜像、任何挂载参数都不可达**」。
前提先钉死（均已用 grep 验证）：

| 前提 | 内容 |
|---|---|
| P1 | `dif->path` 的赋值点仅两处：`Opt_device`（`kstrdup(param->string)`）与守卫①自身 |
| P2 | `extra_devices` 的自增点仅两处：`Opt_device` 与 `erofs_scan_devices()` 的 else 支 |
| P3 | `erofs_init_device()` 的调用点仅两处，都在 `erofs_scan_devices()` 内 |
| P4 | `flatdev` 仅在 `erofs_scan_devices()` 里由 `if (!extra_devices) flatdev = true` 置位 |

于是 `erofs_init_device()` 只有两种进入方式，逐一检查守卫①（`!flatdev && !dif->path`）：

- **if 支**（遍历 idr tree，super.c:219-223）：能走到这里说明 `extra_devices != 0`，
  由 P4 的逆否 ⇒ `flatdev == false`；而 tree 里的 `dif` 全部来自 `Opt_device`，
  由 P1 ⇒ `path` 必非 NULL ⇒ `!dif->path` 为假 ⇒ **守卫①不成立**。
- **else 支**（kzalloc 新 dif，super.c:226-244）：能走到这里说明 `extra_devices == 0`，
  由 P4 ⇒ `flatdev == true` ⇒ `!flatdev` 为假 ⇒ **守卫①不成立**（短路）。

两种进入方式下守卫①恒为假。**所以这两行对任何镜像、任何挂载参数都不可达。**

这个结论只对当前代码成立；只要未来有人新增 `dif->path` 或 `extra_devices` 的赋值点，
论证就需要重做。它本质上是 flatdev 引入时的副作用：`8b465fecc35a` 把
「没给 `-o device=`」的语义从「按 tag 自动扫描设备」改成了「flatdev」，
守卫①因此失去了唯一可能被触发的场景。

---

## 四、erofs_map_dev 的完整实现

这是 flatdev 真正起作用的地方，函数在 `fs/erofs/data.c`。

#### 4.1 入口默认态

```c
erofs_fill_from_devinfo(map, sb, &EROFS_SB(sb)->dif0);
map->m_bdev = sb->s_bdev;	/* use s_bdev for the primary device */
```

`erofs_fill_from_devinfo()` 做三件事：设 `m_sb`、`m_dif = dif`、`m_bdev = NULL`
（仅当 `dif->file` 是块设备时才赋成 `file_bdev()`）。
紧接着 `m_bdev` 被**无条件**覆盖为 `sb->s_bdev`。

⇒ **默认答案就是「主设备、m_pa 原样」**。后面所有分支都只是在这个默认态上做增量修改。

#### 4.2 if 支：`m_deviceid != 0`

```c
if (map->m_deviceid) {
        down_read(&devs->rwsem);
        dif = idr_find(&devs->tree, map->m_deviceid - 1);
        if (!dif) { up_read(&devs->rwsem); return -ENODEV; }

        if (devs->flatdev) {
                map->m_pa += erofs_pos(sb, dif->uniaddr);
                up_read(&devs->rwsem);
                return 0;                       /* ★ 早退 */
        }
        erofs_fill_from_devinfo(map, sb, dif);
        up_read(&devs->rwsem);
}
```

- `idr_find(..., m_deviceid - 1)` 的 `-1`：device id **从 1 开始编号**，0 专指主设备，
  而 idr 索引从 0 起，所以减一。
- **A1 / flatdev**：只做一次地址平移就 `return`。
  关键在于它**没有调用 `erofs_fill_from_devinfo(dif)`**，
  所以 `m_dif` 一直停留在入口设的 `&dif0`。
  这就是「一切都按主设备算」的真正落点——不只是 bdev 不变，`fsoff`、`file` 也全用主设备的。
- **A2 / 非 flatdev**：`m_dif` 换成 `dif`；`m_bdev` 按 `dif->file` 重新算——
  `dif->file` 是块设备则取 `file_bdev()`，是普通文件（fileio）则为 **NULL**（见 §6.1）；
  `m_pa` 不动（它本来就是该设备内的偏移）。

#### 4.3 else if 支：`m_deviceid == 0`

```c
} else if (devs->extra_devices && !devs->flatdev) {
        down_read(&devs->rwsem);
        idr_for_each_entry(&devs->tree, dif, id) {
                if (!dif->uniaddr)
                        continue;
                startoff = erofs_pos(sb, dif->uniaddr);
                if (map->m_pa >= startoff &&
                    map->m_pa < startoff + erofs_pos(sb, dif->blocks)) {
                        map->m_pa -= startoff;
                        erofs_fill_from_devinfo(map, sb, dif);
                        break;
                }
        }
        up_read(&devs->rwsem);
}
return 0;
```

`m_deviceid == 0` 说明地址里没带设备编号，此时 `m_pa` 是**全局地址**，
要反查它落在哪个设备的 `[uniaddr, uniaddr + blocks)` 区间里，再减去 `startoff` 转成段内偏移。

注意：后面**没有 else**。所以：

- `flatdev && m_deviceid == 0` → 条件为假（flatdev 为真），两条都不进
- `!flatdev && m_deviceid == 0` 但区间**未命中** → 循环走完也没 `break`

这两种都直接落到函数末尾的 `return 0`，**保持入口默认态**。

#### 4.4 四种结果汇总

| | 触发条件 | 执行的语句 | m_dif | m_pa | 最终落在 |
|---|---|---|---|---|---|
| **A1** | `m_deviceid` && flatdev | `m_pa += erofs_pos(sb, dif->uniaddr)` + return | `&dif0`（未改） | 段内偏移 + uniaddr | 主设备 |
| **A2** | `m_deviceid` && !flatdev | `erofs_fill_from_devinfo(dif)` | `dif` | 不变（段内偏移） | 额外设备（或其 backing 文件） |
| **B1** | !`m_deviceid` && 有额外设备 && !flatdev && 命中区间 | `m_pa -= startoff` + fill | `dif` | 全局 − uniaddr | 额外设备（或其 backing 文件） |
| **B2** | !`m_deviceid` && (flatdev ‖ 无额外设备 ‖ 未命中) | 无 | `&dif0` | 不变 | 主设备 |

#### 4.5 调用方视角：谁走哪条

`erofs_map_dev()` 有三个调用点，各自带的 `m_deviceid` 不同：

| 调用点 | 场景 | m_deviceid | 走哪支 |
|---|---|---|---|
| `erofs_iomap_begin()`（data.c） | 非压缩 / 元数据 | 来自 `erofs_map_blocks()` | 仅 CHUNK_BASED 布局可能非 0 → A 支；FLAT / COMPRESSED 恒 0 → B 支 |
| `z_erofs_submit_queue()`（zdata.c） | 压缩数据 pcluster | **恒为 0** | B 支 |
| `erofs_fileio_rq_submit()` / `erofs_fileio_read_folio()`（fileio.c） | fileio 读 | 同 iomap | A 支或 B 支 |

前两行的区别来自 `erofs_map_blocks()`：它开头就把 `m_deviceid` 清零，
只有 `erofs_map_chunks()` 会把它设成非 0（因为只有 chunk 索引里才有 device_id 字段）。
**`zmap.c` 里完全没有 `m_deviceid` / `device_id` 字样**——压缩路径根本不碰这个字段。
所以压缩布局恒为 0，不是「清零后碰巧没人设」，而是**格式上就不带**。

zdata 那段自带注释，是 B 支存在理由的最好说明：

```c
/* fs/erofs/zdata.c —— z_erofs_submit_queue() */
/* no device id here, thus it will always succeed */
mdev = (struct erofs_map_dev) {
        .m_pa = round_down(pcl->pos, sb->s_blocksize),
};
(void)erofs_map_dev(sb, &mdev);
```

**压缩数据的 pcluster 在磁盘上写的是全局地址**，本身不带 device id；
多设备靠 uniaddr 区间反查来路由。好处是**不需要改 pcluster 的地址格式**就能支持多设备。
而 `m_deviceid == 0` 永远不会触发 `idr_find` 失败那条 `-ENODEV`，所以注释说 "always succeed"，
返回值也被 `(void)` 丢掉。

#### 4.6 m_pa 到底是相对偏移还是绝对偏移

**分阶段，而且入口处还随 `m_deviceid` 而变**——它有两个参照系。

###### (1) `erofs_map_blocks()` 产出时：由 mkfs 的写法决定

`erofs-utils/lib/blobchunk.c` 写 chunk 索引时：

```c
if (chunk->blkaddr == EROFS_NULL_ADDR) {
        startblk = EROFS_NULL_ADDR;
} else if (chunk->device_id) {
        startblk = chunk->blkaddr;                    /* 段内块号 */
        ...
} else {
        startblk = remapped_base + chunk->blkaddr;    /* 主设备内绝对块号 */
}
```

（`remapped_base` 是**没有额外设备**时，datablob 追加到主镜像尾部的起始块号。）

于是形成一条干净的对应关系：

| 数据来源 | m_deviceid | m_pa 语义 | 参照系 |
|---|---|---|---|
| CHUNK_BASED 且 device_id != 0 | != 0 | 段内偏移 | 该设备起点 |
| CHUNK_BASED 且 device_id == 0 | 0 | 全局地址 | 统一地址空间起点 |
| FLAT / FLAT_INLINE 数据段 | 0 | 全局地址（`vi->startblk` 已被 `erofs_inode_map_flat_blkaddr()` 全局化） | 同上 |
| COMPRESSED（pcluster） | 0 | 全局地址（pstart 同样全局化） | 同上 |
| FLAT_INLINE 的 inline 尾 | 0 | 元数据区地址 | 主设备内 |

**规律：`m_deviceid == 0` ⟺ `m_pa` 是全局地址；`m_deviceid != 0` ⟺ `m_pa` 是段内偏移。**

这不是巧合，而是格式设计的必然：**只有 packed chunk 索引才带 `device_id` 字段**。
既然设备号已经单独存了，块地址就只需要写段内偏移；
反之，没有地方存设备号，就只能在地址里直接写全局位置。

###### (2) `erofs_map_dev()` 出口时：统一成同一种参照系

| 分支 | m_pa | 参照系 |
|---|---|---|
| A1 flatdev | 段内 + uniaddr | 全局地址，但 `m_dif = &dif0` |
| A2 | 不变 | 段内偏移 |
| B1 | 全局 − uniaddr | 段内偏移 |
| B2 | 不变 | 沿用入口语义 |

A1 看似例外（出口仍是全局地址），但因为 `m_dif` 指向 `dif0`、
而**主设备在全局地址空间里的起点恒为 0**，所以数值上就等于「主设备内偏移」，
下游照样按「相对 m_dif」来用。

⇒ 出口的统一语义：**相对于 `m_dif` 所指设备起点的字节偏移**。

###### (3) 最终使用：加上 `fsoff` 才是绝对位置

```c
iomap->addr = mdev.m_dif->fsoff + mdev.m_pa;                 /* iomap 路径 */
bio->bi_iter.bi_sector = (mdev.m_dif->fsoff + cur) >> 9;     /* 压缩路径 */
```

`fsoff` 是设备在 backing 文件里的起始偏移（`-o fsoffset=`，只对主设备有效）。
**`m_dif->fsoff + m_pa` 才是 backing 上的绝对字节偏移。**

一句话：

> `m_pa` 在入口是「随 `m_deviceid` 变化的段内偏移 / 全局地址」，
> 在出口统一为「相对 `m_dif` 的偏移」；
> 只有 `fsoff + m_pa` 才是绝对的。

---

## 五、地址是怎么编码的（格式层面）

这一节的内容不是内核私有实现——`erofs-utils` 里有同构代码，说明它是**磁盘格式约定**。

#### 5.1 device id 藏在 bit48 以上

```c
/* fs/erofs/data.c —— erofs_map_chunks() */
if (unit == EROFS_BLOCK_MAP_ENTRY_SIZE) {
        addr = le32_to_cpu(((__le32 *)idx)[nr]);          /* legacy 4 字节，无 device_id */
} else {
        addr = (((u64)le16_to_cpu(idx[nr].startblk_hi) << 32) |
                le32_to_cpu(idx[nr].startblk_lo)) & addrmask;
        if (addr ^ (EROFS_NULL_ADDR & addrmask))
                addr |= (u64)(le16_to_cpu(idx[nr].device_id) &
                        EROFS_SB(sb)->device_id_mask) << 48;   /* ★ */
        else
                addr = EROFS_NULL_ADDR;
}

map->m_pa = erofs_pos(sb, last & addrmask) - map->m_llen;
map->m_deviceid = last >> 48;                                 /* ★ */
```

物理块地址被扩成 64 位：**低 48 位（或低 32 位）是块号，高 16 位复用为 device id**。
`device_id_mask = roundup_pow_of_two(ondisk_extradevs + 1) - 1`，只取有效低位。

用户态 `erofs-utils/lib/data.c` 的 `erofs_map_dev()` 解析方式完全一致：

```c
map->m_deviceid = le16_to_cpu(idx->device_id) & sbi->device_id_mask;
```

#### 5.2 两个标志位是独立的

这点是容易混的地方——它们**不是一回事**：

| 标志 | 值 | 决定什么 |
|---|---|---|
| `EROFS_CHUNK_FORMAT_INDEXES` | 0x20 | `unit`：走 packed 索引（**带 device_id 字段**）还是 4 字节 legacy |
| `EROFS_CHUNK_FORMAT_48BIT` | 0x40 | `addrmask`：`BIT_ULL(48)-1` 还是 `BIT_ULL(32)-1` |

⇒ 不是「开了 48BIT 才有 device id」。决定有没有 device id 的是 **INDEXES**；
而 `m_deviceid = last >> 48` 是硬编码位移，与 `addrmask` 取 48 还是 32 **无关**。

#### 5.3 用户态同构：mkfs 侧怎么生成

`erofs-utils` 里有两个函数与内核严格对应。

**(a) uniaddr 的生成** —— `erofs_write_device_table()`（`erofs-utils/lib/super.c`）：

```c
erofs_blk_t nblocks = sbi->primarydevice_blocks;   /* 从主设备的块数起步 */
do {
        struct erofs_deviceslot dis = {
                .uniaddr_lo = cpu_to_le32(nblocks),        /* 当前累积块数 */
                .blocks_lo  = cpu_to_le32(sbi->devs[i].blocks),
                .blocks_hi  = cpu_to_le16(sbi->devs[i].blocks >> 32),
                .uniaddr_hi = cpu_to_le16(nblocks >> 32),
        };
        ...
        nblocks += sbi->devs[i].blocks;                /* 累加给下一个设备 */
} while (...);
```

⇒ **`uniaddr` = 主设备块数 + 前面所有额外设备的块数**，即各设备首尾相接后的起点。
**第一个额外设备的 `uniaddr` 等于主设备的块数，不可能是 0。**

**(b) 段内地址 → 全局地址** —— `erofs_inode_map_flat_blkaddr()`（`erofs-utils/lib/inode.c`）：

```c
dev_id = inode->u.i_blkaddr >> EROFS_I_BLKADDR_DEV_ID_BIT;   /* BIT = 48 */
if (!dev_id)
        return 0;
if (dev_id <= sbi->extra_devices) {
        dev_startblk = sbi->devs[dev_id - 1].uniaddr;
} else {
        dev_startblk = sbi->metazone_startblk;      /* dev_id == extra_devices + 1：元数据区 */
}
inode->u.i_blkaddr = erofs_inode_dev_baddr(inode) + dev_startblk;   /* ★ 落盘前转全局 */
```

函数名就叫 `map_flat_blkaddr`。**写盘前把「设备内地址」加上 `uniaddr` 变成全局地址**，
这就是 4.5 里「pcluster 记的是全局地址」的直接来源。

顺带解释一个容易误会的点：`dev_id` 空间里还有一个 `extra_devices + 1`，
专指**元数据区**（metazone）。它只存在于 mkfs 内部对 `i_blkaddr` 的编码中，
落盘前已转成全局地址，不会出现在 chunk 索引的 `device_id` 字段里，
所以不受 `device_id_mask` 位宽的限制。

**(c) 用户态读取也做同样的区间反查** —— `erofs_map_dev()`（`erofs-utils/lib/data.c`）
与内核版几乎逐行对应，只是更简（不切换 `dif` 指针，因为用户态直接用 `sbi->devs` 数组）：

```c
} else if (sbi->extra_devices) {
        for (id = 0; id < sbi->extra_devices; ++id) {
                dif = sbi->devs + id;
                if (!dif->uniaddr)
                        continue;
                startoff = erofs_pos(sbi, dif->uniaddr);
                length = erofs_pos(sbi, dif->blocks);
                if (map->m_pa >= startoff && map->m_pa < startoff + length) {
                        map->m_pa -= startoff;
                        break;
                }
        }
}
```

#### 5.4 完整换算链

```
chunk 索引里的 addr（64 位）
   ├─ bit0..47（48BIT）或 bit0..31（非 48BIT） : 块号（& addrmask）
   └─ bit48..63                                : device id（>> 48）
                        │
erofs_map_dev()
   ├─ A1 flatdev  : m_pa += uniaddr，m_dif 保持 &dif0
   ├─ A2          : m_dif = dif
   └─ B1          : m_pa -= uniaddr，m_dif = dif
                        │
最终 backing 上的位置 = m_dif->fsoff + m_pa          （erofs_iomap_begin）
DAX 时再加            + m_dif->dax_part_off
压缩路径同理：bi_sector = (m_dif->fsoff + cur) >> 9  （z_erofs_submit_queue）
```

---

## 六、四个实现细节

#### 6.1 `m_bdev` 可以为 NULL

```c
/* erofs_fill_from_devinfo() */
map->m_sb = sb;
map->m_dif = dif;
map->m_bdev = NULL;
if (dif->file && S_ISBLK(file_inode(dif->file)->i_mode))
        map->m_bdev = file_bdev(dif->file);
```

fileio 模式下 `dif->file` 是普通文件 ⇒ **`m_bdev` 为 NULL**。此时 I/O 根本不走 bdev：

```c
/* erofs_fileio_rq_submit() */
rq->iocb.ki_filp = mdev->m_dif->file;
```

zdata 侧据此分派：

```c
/* z_erofs_submit_queue() */
if (!bio) {
        if (erofs_is_fileio_mode(EROFS_SB(sb)))
                bio = erofs_fileio_bio_alloc(&mdev);       /* 用 mdev.m_dif->file */
        else
                bio = bio_alloc(mdev.m_bdev, BIO_MAX_VECS,  /* 只有这条用 m_bdev */
                                REQ_OP_READ, GFP_NOIO);
        bio->bi_end_io = z_erofs_endio;
        bio->bi_iter.bi_sector = (mdev.m_dif->fsoff + cur) >> 9;
        ...
}
...
if (bio) {
        if (erofs_is_fileio_mode(EROFS_SB(sb)))
                erofs_fileio_submit_bio(bio);
        else
                submit_bio(bio);
}
```

⇒ `m_bdev` 为空是 fileio 的**正常状态**，不是异常。
另外 zdata 累积 bio 时会用 `cur != last_pa || bio->bi_bdev != mdev.m_bdev` 判断
要不要先把当前 bio 排掉再开新的：连续读取路径上，**相邻数据块**（可能来自不同 pcluster）
一旦落点不连续、或换了设备，就得先 drain。

#### 6.2 `fsoff` 只对主设备生效

`fsoff` 只有一个赋值点，且对象是 **`dif0`**：

```c
/* erofs_fc_parse_param() */
case Opt_fsoffset:
        sbi->dif0.fsoff = result.uint_64;
        break;
```

额外设备的 `dif` 是 `kzalloc` 出来的，`fsoff` 恒为 0。于是：

```c
iomap->addr = mdev.m_dif->fsoff + mdev.m_pa;
```

- 走 A1 / B2（`m_dif = &dif0`）⇒ `fsoff` 生效
- 走 A2 / B1（`m_dif = dif`）⇒ `fsoff` 为 0

**`-o fsoffset=` 只对主设备有效。** 元数据缓冲区同理：`erofs_bread()` 里 `buf->off = sbi->dif0.fsoff`。

#### 6.3 `uniaddr == 0` 的 slot 被跳过

```c
if (!dif->uniaddr)
        continue;
```

从 5.3(a) 可知，正常镜像里额外设备的 `uniaddr` 从主设备块数起步，**不会是 0**。
所以这里跳过的是**未初始化或异常的 slot**（`kzalloc` 之后还没被填上有效值的那种）。
用户态 `erofs-utils/lib/data.c` 的 `erofs_map_dev()` 用的是同一个判据，语义一致。

#### 6.4 flatdev 不做任何校验

`erofs_scan_devices()` 在 flatdev 分支里只读 `blocks` / `uniaddr`，
**不检查这些区间是否真的落在主设备范围内**，也不检查各区间是否重叠。
它把「数据确实都在主设备里」当作**调用方的前提**。

如果这个前提不成立，后果是静默读错或 I/O 错误——所以 flatdev 只适合
「镜像生成方与部署方约定好布局」的场景（见第七章）。

---

## 七、设计意图与来历

#### 7.1 主提交

`8b465fecc35a`（Jia Zhu，2023-03-02，v6.3）
*erofs: support flattened block device for multi-blob images*

> In order to support mounting multi-blobs container image as a single block device,
> add flattened block device feature for EROFS. In this mode, all meta/data contents will
> be mapped into one block space. User could compose a block device (by nbd / ublk /
> virtio-blk / vhost-user-blk) from multiple sources and mount the block device by EROFS
> directly. **It can reduce the number of block devices used**, and it's also benefits in
> both VM file passthrough and distributed storage scenarios.

典型场景是**容器镜像**：Nydus / Dragonfly 那类 image-service 把多个 blob 合成一个
nbd（或 ublk / virtio-blk / vhost-user-blk）设备，EROFS 直接挂它。
原本要 N 个块设备，现在只要 1 个。

#### 7.2 配套修复

`f939aeea7ab7`（Jingbo Xu，2023-09-15）
*erofs: allow empty device tags in flatdev mode*

> Device tags aren't actually required in flatdev mode, thus fix mount failure due to
> empty device tags in flatdev mode.

flatdev 下 `tag` 本就无意义，但旧代码仍要求 tag 非空，导致这类镜像挂载直接 `-EINVAL`。
这个提交把守卫改成 `if (!sbi->devs->flatdev && !dif->path)`，即今天看到的形态。

---

## 八、怎么触发与验证

#### 触发条件（checklist）

1. 镜像：`mkfs.erofs --chunksize=N --blobdev=X ...` 造出带 device table 的镜像
2. 挂载：**不**给任何 `-o device=`，只给主设备
3. 于是 `sbi->devs->extra_devices == 0` ⇒ `flatdev = true`

前提：这些 blob 的内容确实已经被拼接到主设备上（否则见 6.4）。

#### 验证手段

```sh
# 1. 确认镜像带 device table
dump.erofs -s <img> | grep "incompatible features"
#   应形如：Filesystem incompatible features:  lz4_0padding chunked_file device_table

# 2. 确认挂载没给额外设备
cat /proc/self/mountinfo | grep erofs

# 3. 内核侧：kprobe 观察 m_deviceid / m_pa
#    erofs_map_dev(sb, map) 两个参数：%di = sb，%si = map
#    entry 探针只能读到函数【修改前】的 m_pa；要看平移后的结果，加一条 return 探针。
#    结构体偏移（64 位）：m_pa = +24，m_deviceid = +32
#    return probe 里寄存器已被函数体复用，要用 $arg2（入口时保存的参数），别用 %si
echo 'p:md_in  erofs_map_dev m_deviceid=+32($arg2):x32 m_pa_in=+24($arg2):x64' >> /sys/kernel/tracing/kprobe_events
echo 'r:md_out erofs_map_dev m_pa_out=+24($arg2):x64' >> /sys/kernel/tracing/kprobe_events
echo 1 > /sys/kernel/tracing/events/kprobes/enable
#    flatdev 下预期：m_deviceid != 0，且 m_pa_out = m_pa_in + uniaddr × 块大小
#    （通用探针写法参考 /home/linux/erofs/trace-bash-fork.sh）
```

更省事的办法是 ftrace 计数：把 `erofs_map_dev` 与 `erofs_fill_from_devinfo`
一起放进 `set_ftrace_filter`，统计两者调用次数。

- flatdev 走 A1 是 **return 早退，不调后者** ⇒ 两个计数**不相等**
- 非 flatdev 且命中区间时会调后者 ⇒ 计数**相等**

这正好把「`m_dif` 停在 `&dif0`」这个核心差异变成可测的。

---

## 九、小结

| 项 | 内容 |
|---|---|
| 是什么 | `struct erofs_dev_context.flatdev`，运行态推断标志，非格式字段、非挂载选项 |
| 何时为真 | 镜像有 device table 且 `extra_devices > 0`，但挂载时一个 `-o device=` 都没给 |
| 语义 | 多个"设备"都摊平在同一个块设备上，device slot 实际是主设备里的地址区间 |
| 直接效果 | 不解析 tag、不 open 设备；`dif->file` 恒为 NULL |
| 核心差异 | A1 分支 `return` 早退 ⇒ `m_dif` 保持 `&dif0`，`fsoff`/`file` 全按主设备算 |
| 地址换算 | `m_pa += uniaddr`（A1）/ `m_pa -= uniaddr`（B1）；最终 `m_dif->fsoff + m_pa` |
| uniaddr 由来 | 主设备块数 + 前面各额外设备块数之和（mkfs 侧累加生成） |
| device id | 藏在物理块地址 bit48~63；有无由 `CHUNK_FORMAT_INDEXES` 决定，与 `48BIT` 无关 |
| 四种结果 | A1 主设备 / A2 额外设备 / B1 额外设备 / B2 主设备（含短路） |
| 校验 | 无。内核只做地址平移，假定数据都在主设备里 |
| 设计目的 | 容器镜像把多 blob 合成单块设备，减少块设备数量（v6.3，`8b465fecc35a`） |


## 参考
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)  
[erofs-utils(1.9.4)](https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git)  
[linux-stable (2f2f7eeef8b0)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  