---
layout:     post
title:      EROFS Super Block
subtitle:   EROFS 超级块
date:       2026-10-12
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
---

# 27 · EROFS 超级块（Super Block）

> **源码依据**
>
> - 内核：`/home/linux/erofs/linux-stable`，`fs/erofs/erofs_fs.h`、`fs/erofs/super.c`（`v7.3-rc7` 之后的 master）
> - 用户态：`/home/linux/erofs/erofs-utils` 1.9.4，`include/erofs_fs.h`、`lib/super.c`
>
> **定位约定**：本文按「文件路径 + 函数名 / 字段名」定位，不绑定行号——树会随上游推进，行号会漂移。  
> 文中所有字段偏移均由 `offsetof` 程序实测得出（见 §8.3），非手工推算。
>
> **一致性前提**：内核 `fs/erofs/erofs_fs.h` 与 erofs-utils `include/erofs_fs.h`  
> 中的 `struct erofs_super_block` 定义已核对一致（仅空白字符差异），故本文的偏移表对两侧同时成立。

---

## 目录

- [一、概述：超级块在哪、多大](#一概述超级块在哪多大)
- [二、结构体完整定义与字段表](#二结构体完整定义与字段表)
- [三、磁盘布局](#三磁盘布局)
- [四、sb_extslots 与扩展槽位](#四sb_extslots-与扩展槽位)
- [五、内核挂载时的解析与校验](#五内核挂载时的解析与校验)
- [六、erofs-utils 的生成逻辑](#六erofs-utils-的生成逻辑)
- [七、特性位一览](#七特性位一览)
- [八、实测数据附录](#八实测数据附录)
- [九、小结](#九小结)

---

## 一、概述：超级块在哪、多大

EROFS 是只读文件系统，超级块是整卷的唯一入口。三个基本常量决定了它的位置与规模：

| 常量                    | 值           | 出处                  |
| ----------------------- | ------------ | --------------------- |
| `EROFS_SUPER_MAGIC_V1`  | `0xE0F5E1E2` | `fs/erofs/erofs_fs.h` |
| `EROFS_SUPER_OFFSET`    | `1024`       | 同上                  |
| `EROFS_SB_EXTSLOT_SIZE` | `16`         | 同上                  |

**一句话定位**：超级块总是位于**镜像字节偏移 1024 处**（`EROFS_SUPER_OFFSET`，与块大小无关），  

基准大小 128 字节，并可通过 `sb_extslots` 按 16 字节粒度增长，上限为一个页帧减去 1024。  

`sizeof(struct erofs_super_block)` = **144**——这已经包含了最大情况下的一个扩展槽（128 基础 + 16 扩展）。

---

## 二、结构体完整定义与字段表

#### 2.1 源码出处

- 内核：`fs/erofs/erofs_fs.h`
- 用户态：`erofs-utils/include/erofs_fs.h`

两者同名同构。

#### 2.2 完整定义

```c
/* erofs on-disk super block (currently 144 bytes at maximum) */
struct erofs_super_block {
	__le32 magic;           /* file system magic number */
	__le32 checksum;        /* crc32c to avoid unexpected on-disk overlap */
	__le32 feature_compat;
	__u8 blkszbits;         /* filesystem block size in bit shift */
	__u8 sb_extslots;	/* superblock size = 128 + sb_extslots * 16 */
	union {
		__le16 rootnid_2b;	/* nid of root directory */
		__le16 blocks_hi;	/* (48BIT on) blocks count MSB */
	} __packed rb;
	__le64 inos;            /* total valid ino # (== f_files - f_favail) */
	__le64 epoch;		/* base seconds used for compact inodes */
	__le32 fixed_nsec;	/* fixed nanoseconds for compact inodes */
	__le32 blocks_lo;	/* blocks count LSB */
	__le32 meta_blkaddr;	/* start block address of metadata area */
	__le32 xattr_blkaddr;	/* start block address of shared xattr area */
	__u8 uuid[16];          /* 128-bit uuid for volume */
	__u8 volume_name[16];   /* volume name */
	__le32 feature_incompat;
	union {
		/* bitmap for available compression algorithms */
		__le16 available_compr_algs;
		/* customized sliding window size instead of 64k by default */
		__le16 lz4_max_distance;
	} __packed u1;
	__le16 extra_devices;	/* # of devices besides the primary device */
	__le16 devt_slotoff;	/* startoff = devt_slotoff * devt_slotsize */
	__u8 dirblkbits;	/* directory block size in bit shift */
	__u8 xattr_prefix_count;	/* # of long xattr name prefixes */
	__le32 xattr_prefix_start;	/* start of long xattr prefixes */
	__le64 packed_nid;	/* nid of the special packed inode */
	__u8 xattr_filter_reserved; /* reserved for xattr name filter */
	__u8 ishare_xattr_prefix_id;
	__u8 reserved[2];
	__le32 build_time;	/* seconds added to epoch for mkfs time */
	__le64 rootnid_8b;	/* (48BIT on) nid of root directory */
	__le64 reserved2;
	__le64 metabox_nid;     /* (METABOX on) nid of the metabox inode */
	__le64 reserved3;	/* [align to extslot 1] */
};
```

#### 2.3 字段说明表

偏移与大小由 `offsetof` / `sizeof` 实测（编译器 GCC，x86-64，LP64）：

| 字段                     | 偏移 | 大小 | 含义                                                        |
| ------------------------ | ---- | ---- | ----------------------------------------------------------- |
| `magic`                  | 0    | 4    | 魔数，必须为 `0xE0F5E1E2`                                   |
| `checksum`               | 4    | 4    | 超级块 CRC32C 校验和（`SB_CHKSUM` 特性启用时有效）          |
| `feature_compat`         | 8    | 4    | 兼容特性位图                                                |
| `blkszbits`              | 12   | 1    | 文件系统块大小的对数（`1 << blkszbits`）                    |
| `sb_extslots`            | 13   | 1    | **扩展槽数量**，见 §4                                       |
| `rb`（union）            | 14   | 2    | `rootnid_2b`（根 inode nid）或 `blocks_hi`（48 位块数高位） |
| `inos`                   | 16   | 8    | 有效 inode 总数                                             |
| `epoch`                  | 24   | 8    | compact inode 的时间基准（秒）                              |
| `fixed_nsec`             | 32   | 4    | compact inode 的固定纳秒部分                                |
| `blocks_lo`              | 36   | 4    | 主设备块数（低 32 位）                                      |
| `meta_blkaddr`           | 40   | 4    | **元数据区起始块号**                                        |
| `xattr_blkaddr`          | 44   | 4    | 共享 xattr 区起始块号                                       |
| `uuid`                   | 48   | 16   | 卷 UUID                                                     |
| `volume_name`            | 64   | 16   | 卷名（NUL 结尾字符串，可全零）                              |
| `feature_incompat`       | 80   | 4    | **不兼容特性位图**，见 §7                                   |
| `u1`（union）            | 84   | 2    | `available_compr_algs`（算法位图）或 `lz4_max_distance`     |
| `extra_devices`          | 86   | 2    | 除主设备外的设备数量                                        |
| `devt_slotoff`           | 88   | 2    | device table 起始位置，单位是 128 字节 slot                 |
| `dirblkbits`             | 90   | 1    | 目录块大小对数，**当前内核要求为 0**                        |
| `xattr_prefix_count`     | 91   | 1    | 长 xattr 名前缀数量                                         |
| `xattr_prefix_start`     | 92   | 4    | 长 xattr 名前缀表起始块号                                   |
| `packed_nid`             | 96   | 8    | 特殊 packed inode 的 nid                                    |
| `xattr_filter_reserved`  | 104  | 1    | xattr 名过滤器预留                                          |
| `ishare_xattr_prefix_id` | 105  | 1    | ishare xattr 前缀 id                                        |
| `reserved`               | 106  | 2    | 预留                                                        |
| `build_time`             | 108  | 4    | 相对 `epoch` 的构建秒数                                     |
| `rootnid_8b`             | 112  | 8    | 48 位布局下的根 inode nid                                   |
| `reserved2`              | 120  | 8    | 预留（基础区到此结束）                                      |
| `metabox_nid`            | 128  | 8    | metabox inode 的 nid（**首个扩展槽内**）                    |
| `reserved3`              | 136  | 8    | 预留（对齐到扩展槽 1）                                      |

#### 2.4 两处联合体（容易看漏）

**`rb`（偏移 14）**——两种情况二选一：

- 未开 48 位布局：作 `rootnid_2b`，根 inode 的 16 位 nid
- 开 48 位布局（`EROFS_FEATURE_INCOMPAT_48BIT`）：作 `blocks_hi`，块数的高 16 位，  
  与 `blocks_lo` 拼成 48 位块数；此时根 nid 改存 `rootnid_8b`

**`u1`（偏移 84）**——两种情况二选一：

- 有 `COMPR_CFGS` 特性：作 `available_compr_algs`，可用压缩算法位图
- 否则：作 `lz4_max_distance`，LZ4 自定义滑动窗口大小

---

## 三、磁盘布局

#### 3.1 块 0 全景

```text
┌─ 0x0000 (0) ───────────────────────────────────────────────┐
│  预留区 1024 B                                              │
│  供 x86 boot sector 等使用，EROFS 不写入内容                │
├─ 0x0400 (1024) ── EROFS_SUPER_OFFSET ──────────────────────┤
│  superblock 基础区 128 B                                    │
│  magic·checksum·feature_compat·blkszbits·sb_extslots·rb·   │
│  inos·epoch·fixed_nsec·blocks_lo·meta_blkaddr·             │
│  xattr_blkaddr·uuid·volume_name·feature_incompat·u1·        │
│  extra_devices·devt_slotoff·…·reserved2                     │
├─ 0x0480 (1152) ── 1024 + 128 ──────────────────────────────┤
│  扩展槽 × sb_extslots（每槽 16 B）                          │
│  第 1 槽内容：metabox_nid + reserved3                       │
├─ 1024 + sb_size ───────────────────────────────────────────┤
│  压缩配置表（变长，仅 COMPR_CFGS 特性存在时）               │
├─ devt_slotoff × 128 ───────────────────────────────────────┤
│  device table：N × 128 B（仅 DEVICE_TABLE 特性存在时）      │
├─ 0x1000 (4096) ── 块 0 结束（blkszbits = 12 时）───────────┤
```

![磁盘布局](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-10-21-erofs-27-super-block.png)

#### 3.2 前 1024 字节为什么空着

`EROFS_SUPER_OFFSET` 的注释写得很直白：

> `/* to allow for x86 boot sectors and other oddities. */`

即兼容 x86 引导扇区等场景。mkfs 侧写盘时是 `calloc` 出整块再 
`memcpy(buf + EROFS_SUPER_OFFSET, &sb, sbi->sb_size)`，前 1024 字节保持为零。

#### 3.3 压缩配置表与 device table 的顺序

两者都以「superblock 结束处」为锚点，但**依次排布**，不重叠：  
压缩配置表紧接 superblock；若它存在，device table 则在其之后。  
`devt_slotoff` 由 buffer manager 依实际分配位置算出，因此会体现这个后移（实测见 §8.1）。

---

## 四、sb_extslots 与扩展槽位

#### 4.1 定义

```c
__u8 sb_extslots;	/* superblock size = 128 + sb_extslots * 16 */
```

基准 128 字节，每个扩展槽 16 字节（`EROFS_SB_EXTSLOT_SIZE`）：

```
sb_size = 128 + sb_extslots × 16
```

基础区最后一个字段是 `reserved2`（偏移 120-127），
**首个扩展槽（偏移 128-143）容纳后加的 `metabox_nid` 与 `reserved3`**。

#### 4.2 设计目的

引入提交 `14373711dd54`（Gao Xiang，2021-03-29）
*erofs: add on-disk compression configurations*，提交说明：

> Add a bitmap for available compression algorithms and a variable-sized on-disk table
> for compression options in preparation for upcoming big pcluster and LZMA algorithm,
> **which follows the end of super block**.

两个目的：

1. **让超级块可扩展**——早期固定 128 字节，后来要加 `metabox_nid` 等字段时不必改格式
2. **定位变长压缩配置表**——它紧跟超级块末尾，只有知道超级块有多长才找得到

第二点是关键：该配置表长度可变（每个算法跟一段 2 字节 `length` 的数据），  
无法用固定偏移定位，只能用「超级块结束处」作锚点。

#### 4.3 用户态如何计算

`erofs_reserve_sb()`（`erofs-utils/lib/super.c`）：

```c
unsigned int sb_size = 128;
if (erofs_sb_has_metabox(sbi) &&
    sb_size <= offsetof(struct erofs_super_block, metabox_nid))
        sb_size = offsetof(struct erofs_super_block, metabox_nid) + 8;
sbi->sb_size = round_up(sb_size, 16);
```

推导：

- 基础 128
- 启用 metabox ⇒ 需要 `metabox_nid`（偏移 128，8 字节）⇒ 136
- `round_up(136, 16)` ⇒ **144**

写盘时反向编码（`erofs_writesb()`）：

```c
sb.sb_extslots = (sbi->sb_size - 128) >> 4;    /* (144 - 128) / 16 = 1 */
```

**当前只有 metabox 特性会让 `sb_extslots` ≥ 1。**

#### 4.4 内核如何使用

| 用途                        | 代码                                                                                               |
| --------------------------- | -------------------------------------------------------------------------------------------------- |
| 算出 `sb_size`              | `sbi->sb_size = 128 + dsb->sb_extslots * EROFS_SB_EXTSLOT_SIZE;`（`erofs_read_superblock()`）      |
| 校验不超过一个页            | `if (sbi->sb_size > PAGE_SIZE - EROFS_SUPER_OFFSET)` → `-EINVAL`                                   |
| 判断 `metabox_nid` 是否存在 | `if (sbi->sb_size <= offsetof(struct erofs_super_block, metabox_nid))` → `-EFSCORRUPTED`           |
| **定位压缩配置表**          | `offset = EROFS_SUPER_OFFSET + sbi->sb_size;`（`z_erofs_parse_cfgs()`，`fs/erofs/decompressor.c`） |

第三条是**向后兼容守卫**：老镜像超级块只有 128 字节，`metabox_nid` 字段不存在，  
若镜像却声明了 metabox 特性，则判为损坏——防止读到越界数据。

第四条是最实际的用途：`z_erofs_parse_cfgs()` 须先跳过整个超级块，  
才能按 `available_compr_algs` 位图逐个读出各算法的变长配置。

#### 4.5 与整体元数据布局的关系

`sb_extslots` 不直接参与元数据寻址，但通过**改变超级块长度**间接影响后续所有
以「超级块结束处」为锚点的结构：

```
sb_extslots ──► sb_size ──┬──► 压缩配置表起点 = 1024 + sb_size
                          └──► device table 起点（紧贴其后，向上对齐到 128 B slot）
                                    └──► devt_slotoff = ceil((1024 + sb_size) / 128)
```

⚠️ 这个对齐关系意味着 `sb_extslots` 每多 1（超级块增 16 字节）  
**并不总是**让 `devt_slotoff` 加 1——只有跨过 128 字节 slot 边界时才会变。

---

## 五、内核挂载时的解析与校验

#### 5.1 读哪个块

`erofs_read_superblock()`（`fs/erofs/super.c`）开头：

```c
data = erofs_read_metabuf(&buf, sb, 0, false);          /* 读块 0 */
...
dsb = (struct erofs_super_block *)(data + EROFS_SUPER_OFFSET);   /* +1024 */
```

两点需要说清：

- `erofs_read_metabuf()` 的第二参数 `0` 是**镜像字节偏移**，不是块号；  
  它最终交给 `erofs_bread()`，而后者是**按页**读的（`offset >> PAGE_SHIFT` 定页号，`read_cache_folio()` 读整页，返回页内偏移）。  
- `dsb` 再偏移 `EROFS_SUPER_OFFSET`（1024）。

由于按页读、且页大小 ≥ 4096 > 1024 + 128，偏移 1024 处的超级块**总是落在页 0 内**——  
这正是「块大小可为 512 B（`blkszbits` = 9）时，超级块跨块却仍能被正确读出」的原因。  
所以更准确的表述是「超级块位于镜像字节偏移 1024 处」，与块大小无关。

#### 5.2 校验清单

按 `erofs_read_superblock()` 的代码顺序（任一失败即中止挂载）：

| #   | 校验项                                                | 失败返回值      | 条件                            |
| --- | ----------------------------------------------------- | --------------- | ------------------------------- |
| 1   | `magic == EROFS_SUPER_MAGIC_V1`                       | `-EINVAL`       | 恒                              |
| 2   | `9 <= blkszbits <= PAGE_SHIFT`                        | `-EINVAL`       | 恒                              |
| 3   | `dirblkbits == 0`                                     | `-EINVAL`       | 恒                              |
| 4   | CRC32C 校验                                           | `-EBADMSG`      | `SB_CHKSUM` 特性置位时，见 §5.4 |
| 5   | `feature_incompat & ~EROFS_ALL_FEATURE_INCOMPAT` 为 0 | `-EINVAL`       | 恒                              |
| 6   | `sb_size <= PAGE_SIZE - 1024`                         | `-EINVAL`       | 恒（由 `sb_extslots` 算出）     |
| 7   | `ishare_xattr_prefix_id < xattr_prefix_count`         | `-EFSCORRUPTED` | ishare xattr 特性启用时         |
| 8   | `sb_size > offsetof(..., metabox_nid)`                | `-EFSCORRUPTED` | metabox 特性启用时              |
| 9   | `metabox_nid` 不含 `METABOX` 标志位                   | `-EFSCORRUPTED` | metabox 特性启用时（自环检测）  |
| 10  | 无 ZIP 时不含压缩算法位图                             | `-EOPNOTSUPP`   | `CONFIG_EROFS_FS_ZIP` 未开      |
| 11  | `z_erofs_parse_cfgs()`                                | 其返回值        | 恒                              |
| 12  | `erofs_scan_devices()`                                | 其返回值        | 恒                              |

⚠️ **`packed_nid` 的 `METABOX` 位检查只存在于用户态**（`erofs-utils/lib/super.c`），  
内核 `erofs_read_superblock()` 对 `packed_nid` 是**直接赋值、不做该项检查**的，  
不要把它误归到内核挂载流程。内核只查 `metabox_nid` 的 `METABOX` 位（上表第 9 项）。  

补充：48 位布局下根 nid 取 `rootnid_8b`、块数拼 `blocks_hi`；否则取 `rb.rootnid_2b`、块数只用 `blocks_lo`。

#### 5.3 关键步骤源码

```c
/* erofs_read_superblock() —— fs/erofs/super.c */
if (le32_to_cpu(dsb->magic) != EROFS_SUPER_MAGIC_V1) {
        erofs_err(sb, "cannot find valid erofs superblock");
        goto out;
}

sbi->blkszbits = dsb->blkszbits;
if (sbi->blkszbits < 9 || sbi->blkszbits > PAGE_SHIFT) { ... }

sbi->feature_incompat = le32_to_cpu(dsb->feature_incompat);
if (sbi->feature_incompat & ~EROFS_ALL_FEATURE_INCOMPAT) {
        erofs_err(sb, "unidentified incompatible feature %x, please upgrade kernel",
                  sbi->feature_incompat & ~EROFS_ALL_FEATURE_INCOMPAT);
        goto out;
}

sbi->sb_size = 128 + dsb->sb_extslots * EROFS_SB_EXTSLOT_SIZE;
```

#### 5.4 校验和算法

内核 `erofs_superblock_csum_verify()`（`fs/erofs/super.c`）：

```c
u32 len = 1 << EROFS_SB(sb)->blkszbits, crc;
if (len > EROFS_SUPER_OFFSET)
        len -= EROFS_SUPER_OFFSET;
len -= offsetof(struct erofs_super_block, checksum) + sizeof(dsb->checksum);

/* skip .magic(pre-verified) and .checksum(0) fields */
crc = crc32c(0x5045B54A, (&dsb->checksum) + 1, len);
if (crc == le32_to_cpu(dsb->checksum))
        return 0;
```

用户态 `erofs_enable_sb_chksum()`（`erofs-utils/lib/super.c`）写法不同：

```c
/* turn on checksum feature */
sb->feature_compat = cpu_to_le32(le32_to_cpu(sb->feature_compat) |
                                 EROFS_FEATURE_COMPAT_SB_CHKSUM);
*crc = erofs_crc32c(~0, (u8 *)sb, len);      /* len = blksiz - 1024，从偏移 0 起 */
sb->checksum = cpu_to_le32(*crc);
```

**两者数值等价**，只是实现路径不同：

|      | 内核                          | 用户态               |
| ---- | ----------------------------- | -------------------- |
| 起点 | `checksum` 字段之后（偏移 8） | 超级块起始（偏移 0） |
| 长度 | `blksiz - 1024 - 8`           | `blksiz - 1024`      |
| 种子 | `0x5045B54A`                  | `~0`（全 1）         |

**为什么等价**：`0x5045B54A` 正是 CRC32C 在初值全 1 下处理完
「magic（4 B）+ 置零的 checksum（4 B）」这 8 字节后的寄存器值。  
内核用这个常量作种子，正好补偿了被跳过的前 8 字节。

实测验证（`/home/linux/erofs/multidev/main.erofs`，`blkszbits = 12`）：

```text
disk checksum                        = 0xAC43AA14
crc_up(~0,         [0, 3072))        = 0xAC43AA14   ← 匹配
crc_up(0x5045B54A, [8, 3072))        = 0xAC43AA14   ← 匹配
```

两个式子结果与磁盘值三者一致。

注意用户态计算时会先置 `feature_compat |= SB_CHKSUM` 再算 CRC，  
而 `erofs_writesb()` 写盘时先清除该位（`& ~EROFS_FEATURE_COMPAT_SB_CHKSUM`）——  
因为那一刻校验和尚未产生，两者是先后两个步骤。

---

## 六、erofs-utils 的生成逻辑

#### 6.1 预留空间：`erofs_reserve_sb()`

`erofs-utils/lib/super.c`。两个动作：

1. 按 §4.3 的公式算出 `sbi->sb_size`
2. `erofs_bh_balloon(bh, EROFS_SUPER_OFFSET + sbi->sb_size)` —— 把超级块区域「吹」到所需长度，  
   确保后续元数据不会占用这块空间

调用点在 `erofs_buffer_init()`（同文件），即 buffer manager 初始化阶段。

#### 6.2 填充与写盘：`erofs_writesb()`

`erofs-utils/lib/super.c`，由 `mkfs/main.c` 在构建末尾调用。核心流程：

```c
struct erofs_super_block sb = {
        .magic     = cpu_to_le32(EROFS_SUPER_MAGIC_V1),
        .blkszbits = sbi->blkszbits,
        .rb.rootnid_2b  = cpu_to_le16(sbi->root_nid),
        .inos      = cpu_to_le64(sbi->inos),
        .epoch     = cpu_to_le64(sbi->epoch),
        .build_time = cpu_to_le64(sbi->build_time),
        .fixed_nsec = cpu_to_le32(sbi->fixed_nsec),
        .meta_blkaddr  = cpu_to_le32(sbi->meta_blkaddr),
        .xattr_blkaddr = cpu_to_le32(sbi->xattr_blkaddr),
        ...
        .feature_incompat = cpu_to_le32(sbi->feature_incompat),
        .feature_compat = cpu_to_le32(sbi->feature_compat &
                                      ~EROFS_FEATURE_COMPAT_SB_CHKSUM),
        .extra_devices = cpu_to_le16(sbi->extra_devices),
        .devt_slotoff = cpu_to_le16(sbi->devt_slotoff),
        .packed_nid = cpu_to_le64(sbi->packed_nid),
};
```

几个条件分支值得注意：

```c
sb.blocks_lo = cpu_to_le32(sbi->primarydevice_blocks);
if (sbi->primarydevice_blocks > UINT32_MAX || sbi->root_nid > UINT16_MAX) {
        sb.rb.blocks_hi = cpu_to_le16(sbi->primarydevice_blocks >> 32);
        sb.rootnid_8b = cpu_to_le64(sbi->root_nid);        /* 切换为 48 位布局 */
}
...
if (erofs_sb_has_compr_cfgs(sbi))
        sb.u1.available_compr_algs = cpu_to_le16(sbi->available_compr_algs);
else
        sb.u1.lz4_max_distance = cpu_to_le16(sbi->lz4.max_distance);

if (erofs_sb_has_metabox(sbi))
        sb.metabox_nid = cpu_to_le64(sbi->metabox_nid);
sb.sb_extslots = (sbi->sb_size - 128) >> 4;
```

写盘：

```c
buf = calloc(round_up(EROFS_SUPER_OFFSET + sbi->sb_size, erofs_blksiz(sbi)), 1);
memcpy(buf + EROFS_SUPER_OFFSET, &sb, sbi->sb_size);
ret = erofs_dev_write(sbi, buf, sb_bh ? erofs_btell(sb_bh, false) : 0,
                      EROFS_SUPER_OFFSET + sbi->sb_size);
```

即：分配对齐到块大小的缓冲区 → 清零（前 1024 字节保持为 0）→ 复制超级块 → 写入。

#### 6.3 校验和：`erofs_enable_sb_chksum()`

见 §5.4。它在 `erofs_writesb()` 之后单独执行：回读块内容 → 置位 `SB_CHKSUM`
→ 计算 CRC → 填入 `checksum` → 回写。

#### 6.4 完整时序

```text
erofs_buffer_init()
    └── erofs_reserve_sb()          预留 1024 + sb_size，算出 sb_extslots 基数
            ...构建元数据、数据...
erofs_mkfs_init_devices()           分配 device table，算出 devt_slotoff
erofs_writesb()                     填充并写超级块（此时 checksum = 0、SB_CHKSUM 未置位）
erofs_enable_sb_chksum()            回读 → 置位 → 算 CRC → 填回 → 回写
```

---

## 七、特性位一览

#### 7.1 compat（`feature_compat`）

| 位           | 名称                   | 含义                    |
| ------------ | ---------------------- | ----------------------- |
| `0x00000001` | `SB_CHKSUM`            | 启用超级块 CRC32C 校验  |
| `0x00000002` | `MTIME`                | 支持 mtime              |
| `0x00000004` | `XATTR_FILTER`         | xattr 名过滤器          |
| `0x00000008` | `SHARED_EA_IN_METABOX` | 共享 xattr 存于 metabox |
| `0x00000010` | `PLAIN_XATTR_PFX`      | 朴素 xattr 前缀         |
| `0x00000020` | `ISHARE_XATTRS`        | ishare 共享 xattr       |

#### 7.2 incompat（`feature_incompat`）

| 位           | 名称                           | 含义                     |
| ------------ | ------------------------------ | ------------------------ |
| `0x00000001` | `LZ4_0PADDING`                 | LZ4 尾部补零             |
| `0x00000002` | `COMPR_CFGS` / `BIG_PCLUSTER`  | 压缩配置表 / 大 pcluster |
| `0x00000004` | `CHUNKED_FILE`                 | chunk-based 文件         |
| `0x00000008` | `DEVICE_TABLE` / `COMPR_HEAD2` | 设备表 / 压缩头 2        |
| `0x00000010` | `ZTAILPACKING`                 | 尾部 inline 打包         |
| `0x00000020` | `FRAGMENTS` / `DEDUPE`         | fragment / 去重          |
| `0x00000040` | `XATTR_PREFIXES`               | 长 xattr 前缀            |
| `0x00000080` | `48BIT`                        | 48 位地址布局            |
| `0x00000100` | `METABOX`                      | 元数据压缩               |

`EROFS_ALL_FEATURE_INCOMPAT = (METABOX << 1) - 1 = 0x1FF`，
超出此范围的位一律视为「未知不兼容特性」而拒绝挂载。

⚠️ **位复用现象**：`COMPR_CFGS` 与 `BIG_PCLUSTER` 同为 `0x02`；
`DEVICE_TABLE` 与 `COMPR_HEAD2` 同为 `0x08`；`FRAGMENTS` 与 `DEDUPE` 同为 `0x20`。
这些特性两两互斥或由其他条件区分，因此能安全复用同一个位。
`dump.erofs -s` 会把同名的两个特性都列出来（例如同时显示 `compr_cfgs big_pcluster`）。

---

## 八、实测数据附录

#### 8.1 镜像实测表

| 镜像                     | 不兼容特性                             | sb_extslots | sb_size | devt_slotoff | device table 字节 |
| ------------------------ | -------------------------------------- | ----------- | ------- | ------------ | ----------------- |
| `multidev/main.erofs`    | lz4_0padding chunked_file device_table | 0           | 128     | 9            | 1152              |
| `tmp-chunk8/md.erofs`    | （同上）                               | 0           | 128     | 9            | 1152              |
| `a.erofs`（无 metabox）  | lz4_0padding chunked_file device_table | 0           | 128     | 9            | 1152              |
| `b.erofs`（`-m 4096`）   | 含 metabox                             | **1**       | 144     | **10**       | 1280              |
| `c.erofs`（`-C 131072`） | 含 compr_cfgs big_pcluster             | 0           | 128     | **10**       | 1280              |
| `metabox-test/mb.erofs`  | 无 device_table                        | 1           | 144     | 0            | —                 |

`b` 与 `c` 的 `devt_slotoff` 都是 10，但成因不同：

- **b**：`sb_extslots = 1` ⇒ 超级块长 144 ⇒ 结束于 1168 ⇒ 上对齐到 slot 10（1280）
- **c**：`sb_extslots = 0`，但压缩配置表占据 1152 起的一段 ⇒ device table 后移到 1280

#### 8.2 偏移速查

| 想读的字段         | 镜像中的字节偏移      |
| ------------------ | --------------------- |
| `magic`            | 1024 + 0 = **1024**   |
| `checksum`         | 1024 + 4 = **1028**   |
| `feature_compat`   | 1024 + 8 = **1032**   |
| `blkszbits`        | 1024 + 12 = **1036**  |
| `sb_extslots`      | 1024 + 13 = **1037**  |
| `feature_incompat` | 1024 + 80 = **1104**  |
| `extra_devices`    | 1024 + 86 = **1110**  |
| `devt_slotoff`     | 1024 + 88 = **1112**  |
| `metabox_nid`      | 1024 + 128 = **1152** |

#### 8.3 复现方法

**字段偏移表**（§2.3）：

```sh
D=/home/linux/erofs/erofs-utils/include/erofs_fs.h
sed -n '/^struct erofs_super_block {/,/^};/p' $D > /tmp/def.h
# 前置 typedef __le16/__le32/__le64/__u8 + #define __packed
# 拼成 C 文件后 gcc 编译，用 offsetof 打印
```

**读取镜像字段**：

```sh
IMG=<镜像路径>
od -An -tx4 -j 1024 -N 4 $IMG                   # magic
od -An -tu1 -j $((1024+13)) -N 1 $IMG           # sb_extslots
od -An -tx4 -j $((1024+80)) -N 4 $IMG           # feature_incompat
od -An -tu2 -j $((1024+86)) -N 2 $IMG           # extra_devices
od -An -tu2 -j $((1024+88)) -N 2 $IMG           # devt_slotoff
```

**造对照镜像**：

```sh
MK=/home/linux/erofs/utils-x8664/mkfs.erofs
$MK -zlz4 --chunksize=65536 --blobdev=blob.img a.erofs src               # sb_extslots=0
$MK -zlz4 -m 4096 --chunksize=65536 --blobdev=blob.img b.erofs src       # sb_extslots=1
$MK -zlz4 -C 131072 --chunksize=65536 --blobdev=blob.img c.erofs src     # 触发 compr_cfgs
```

---

## 九、小结

| 项             | 结论                                                                                               |
| -------------- | -------------------------------------------------------------------------------------------------- |
| 位置           | 固定位于块 0 偏移 1024（`EROFS_SUPER_OFFSET`）                                                     |
| 大小           | 基准 128 B，按 `128 + sb_extslots × 16` 增长，上限一页减 1024                                      |
| 结构体上限     | `sizeof` = 144（含一个扩展槽）                                                                     |
| 魔数           | `0xE0F5E1E2`                                                                                       |
| 扩展槽作用     | 容纳后加字段（当前为 `metabox_nid`），并提供「超级块结束处」锚点                                   |
| 扩展槽触发条件 | 当前仅 metabox 特性使 `sb_extslots` ≥ 1                                                            |
| 关键下游       | 压缩配置表起点 `1024 + sb_size`；device table 由 `devt_slotoff × 128` 指定                         |
| 校验和         | CRC32C；内核种子 `0x5045B54A`（跳过前 8 B），用户态种子全 1（含前 8 B），两者等价                  |
| 生成流程       | `erofs_reserve_sb` → 构建 → `erofs_mkfs_init_devices` → `erofs_writesb` → `erofs_enable_sb_chksum` |

**理解要点**：`sb_extslots` 本身不存储任何元数据，它只是一个**长度声明**。  
它的价值在于让「超级块之后紧跟着什么、从哪开始」这件事变得可计算——  
压缩配置表和 device table 都以此为锚，从而支持变长结构的定位。

## 参考

[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)  
[erofs-utils(1.9.4)](https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git)  
[linux-stable (2f2f7eeef8b0)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  