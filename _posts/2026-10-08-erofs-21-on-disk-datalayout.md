---
layout:     post
title:      EROFS on-disk layout
subtitle:   EROFS 磁盘镜像布局
date:       2026-10-08
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# EROFS on-disk 镜像格式：5 种 datalayout 完全解析

> **基线**
> - 内核源码：`linux-stable`（Linux 7.3-rc5），结构体取自 `fs/erofs/erofs_fs.h`
> - 用户态：`erofs-utils` 1.9.4（`mkfs.erofs` / `dump.erofs`）
> - **统一假设**：块大小 **4096 B**（`blkszbits=12`）、**小端序**、mkfs 标准布局（无 metabox、无 48bit 时）
>
> **偏移数据来源**：本文所有结构体字段偏移用 `offsetof` 实测（编译运行 `tmp_struct_offsets.c`），  
> 结构体总大小与内核 `BUILD_BUG_ON` 一致：super=144、inode compact=32 / extended=64、  
> xattr_ibody_header=12、xattr_entry=4、chunk_index=8、map_header=8、lcluster_index=8、dirent=12、deviceslot=128。  
> 标注「实测」的数值来自本机真实镜像，标注「示意」的为说明用示例值。

---

## 0. 关键公式与术语

| 名称 | 公式 | 说明 |
|---|---|---|
| `erofs_iloc(inode)` | `meta_blkaddr * bs + nid * 32` | inode 在镜像中的**字节偏移**；`nid` 是 32 B 槽位号，不是序号连续的小整数 |
| `erofs_pos(sb, blk)` | `blk << blkszbits` | 块号 → 字节偏移 |
| `erofs_blkoff(sb, pos)` | `pos & (bs - 1)` | 字节偏移 → 块内偏移 |
| `erofs_iblks(inode)` | `round_up(i_size, bs) >> blkszbits` | 文件占几个块 |
| inode 槽位 | 32 B 固定（与 compact inode 尺寸对齐） | extended inode 占 2 个槽位 |
| `inode_isize` | compact=32 / extended=64 | 由 `i_format` bit0 决定 |
| `xattr_isize` | `i_xattr_icount ? 12 + (n-1)*4 : 0` | `erofs_xattr_ibody_size()` |
| 元数据区起点 | `meta_blkaddr`（实测小镜像常为 **0**） | 元数据可与数据区交错（erofs.rst） |

---

## 1. 镜像全局布局

```
 字节偏移
 0          1024        1152                                            4096
 +-----------+-----------+------------------------------------------------+
 | reserved  |superblock |  metadata area（元数据区）                       |
 |  1 KB     |  128 B    |  inode slots(32B each) + xattr ibody            |
 | (boot等)  | (可扩到   |  + chunk index 数组 / zmap header+索引 / idata   |
 |           |  144 B)   |  + dirent 数据                                  |
 +-----------+-----------+------------------------------------------------+
 |<-- block 0 ---------------------------------------------------------->|

 block 1 .. M-1                block M .. N-1
 +-------------------------+   +------------------------------------------+
 | metadata（继续）         |   | data area（数据区）                        |
 | 若 meta 区放不下会继续   |   | flat 数据块 / pcluster / chunk / blob 引用 |
 +-------------------------+   +------------------------------------------+
```

#### 块 0 细部（实测锚点）

```
 offset  内容
 0        保留（前 1 KB，留给 x86 boot sector 等）
 1024     erofs_super_block（magic = E0 F5 E1 E2 小端 → e2 e1 f5 e0）
 1152     superblock 结束（sb_extslots=0 时 128 B）
          元数据从这里开始：实测 root nid 38 → 38*32 = 1216
```

> 实测（`simple.erofs`）：`blocks=4`、`inode metadata start block = 0`、
> root `nid=38` → offset 1216、`a.txt nid=43` → 1376、`big.bin nid=47` → 1504。

#### 三个区域的关系

| 区域 | 内容 | 是否位置固定 |
|---|---|---|
| superblock | 镜像总描述 | **唯一固定**（offset 1024） |
| metadata area | inode 槽位、xattr ibody、chunk 索引、压缩索引、idata、dirent | 由 `meta_blkaddr` 起点 + `nid` 算出 |
| data area | 文件数据块 / pcluster / chunk | 由 inode 里的 `blkaddr` 索引 |

> 官方描述：`Mixed metadata with data` —— 元数据与数据**可交错**，
> 没有一条硬性的「元数据区/数据区」分界线（见 erofs.rst）。

---

## 2. 结构体字段级解析总表

#### 2.1 `struct erofs_super_block`（144 B，位于 offset 1024）

| 偏移 | 字节 | 字段 | 含义 | 典型值 |
|---|---|---|---|---|
| 0 | 4 | `magic` | 魔数 | `0xE0F5E1E2` |
| 4 | 4 | `checksum` | crc32c（防与其它结构意外重叠） | 实测 `0xe1e36503` |
| 8 | 4 | `feature_compat` | 兼容特性位 | `sb_csum/mtime/xattr_filter` |
| 12 | 1 | `blkszbits` | 块大小位移 | **12**（4096） |
| 13 | 1 | `sb_extslots` | 扩展槽数，sb 大小 = 128 + n*16 | 0（→128 B） |
| 14 | 2 | `rb` | union：rootnid_2b / blocks_hi | root nid |
| 16 | 8 | `inos` | 有效 inode 数 | 实测 6 / 12 |
| 24 | 8 | `epoch` | compact inode 的时间基准（秒） | mkfs 时间 |
| 32 | 4 | `fixed_nsec` | compact inode 固定纳秒 | 0 |
| 36 | 4 | `blocks_lo` | 总块数（LSB） | 实测 4 / 5 / 9 |
| 40 | 4 | `meta_blkaddr` | **元数据区起始块** | 实测 **0** |
| 44 | 4 | `xattr_blkaddr` | shared xattr 区起始块 | 0（无）或有效块号 |
| 48 | 16 | `uuid` | 卷 UUID | 随机 |
| 64 | 16 | `volume_name` | 卷名 | 空 |
| 80 | 4 | `feature_incompat` | **不兼容特性位**（决定能否挂载） | 见下表 |
| 84 | 2 | `u1` | union：available_compr_algs / lz4_max_distance | 实测 `0xffff`(65535) |
| 86 | 2 | `extra_devices` | **除主设备外的设备数** | 实测 **1** |
| 88 | 2 | `devt_slotoff` | device table 起始（×128 B） | 实测 9 |
| 90 | 1 | `dirblkbits` | 目录块大小位移 | 12 |
| 91 | 1 | `xattr_prefix_count` | 长 xattr 名前缀数 | 0 |
| 92 | 4 | `xattr_prefix_start` | 长前缀区起始 | 0 |
| 96 | 8 | `packed_nid` | **packed inode 的 nid**（fragment / 全文件打包） | 0 或有效 nid |
| 104 | 1 | `xattr_filter_reserved` | xattr 过滤保留 | |
| 105 | 1 | `ishare_xattr_prefix_id` | ishare xattr 前缀 id | |
| 106 | 2 | `reserved` | | |
| 108 | 4 | `build_time` | 相对 epoch 的 mkfs 秒数 | |
| 112 | 8 | `rootnid_8b` | 48bit 开启时的 root nid | |
| 120 | 8 | `reserved2` | | |
| 128 | 8 | `metabox_nid` | METABOX 开启时的 metabox inode nid | |
| 136 | 8 | `reserved3` | | |

**`feature_incompat` 常用位**

| 位值 | 名称 | 含义 |
|---|---|---|
| 0x01 | `LZ4_0PADDING` | lz4 压缩尾部用 0 补齐（**压缩数据放块尾**） |
| 0x04 | `CHUNKED_FILE` | 存在 chunk-based 文件 |
| 0x08 | `DEVICE_TABLE` | 存在 device table（多设备） |
| 0x10 | `ZTAILPACKING` | 压缩尾部内联（ztailpacking） |
| 0x20 | `FRAGMENTS` / `DEDUPE` | fragment / 去重 |
| 0x80 | `48BIT` | 48 位块地址 |
| 0x100 | `METABOX` | 元数据压缩（metabox） |

---

#### 2.2 `struct erofs_inode_compact`（32 B）

| 偏移 | 字节 | 字段 | 含义 | 典型值 |
|---|---|---|---|---|
| 0 | 2 | `i_format` | bit0=版本(0=compact)，**bit1-3=datalayout**，bit4=nlink_1/点省略 | 见 §3 |
| 2 | 2 | `i_xattr_icount` | inline xattr 计数（决定 xattr_isize） | 实测 1 → xattr_isize 12；实测共享时 16 B 区 |
| 4 | 2 | `i_mode` | 文件类型+权限 | `0x81a4`(普通 0644) / `0x41ed`(目录 0755) |
| 6 | 2 | `i_nb` | union：nlink / blocks_hi / startblk_hi | |
| 8 | 4 | `i_size` | **文件大小（32 位）** | 实测 95 / 12288 |
| 12 | 4 | `i_mtime` | 修改时间（相对 epoch） | |
| 16 | 4 | `i_u` | **union**：startblk_lo / blocks_lo / rdev / chunk_info | 按 datalayout 解释（见 §3） |
| 20 | 4 | `i_ino` | 32 位 stat 兼容用 inode 号 | |
| 24 | 2 | `i_uid` | | |
| 26 | 2 | `i_gid` | | |
| 28 | 4 | `i_reserved` | | |

#### 2.3 `struct erofs_inode_extended`（64 B）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 2 | `i_format` | bit0=**1**（extended） |
| 2 | 2 | `i_xattr_icount` | 同上 |
| 4 | 2 | `i_mode` | |
| 6 | 2 | `i_nb` | union |
| 8 | **8** | `i_size` | **文件大小（64 位，支持 >4 GiB）** |
| 16 | 4 | `i_u` | 同 compact 的 union |
| 20 | 4 | `i_ino` | |
| 24 | 4 | `i_uid` | |
| 28 | 4 | `i_gid` | |
| 32 | 8 | `i_mtime` | |
| 40 | 4 | `i_mtime_nsec` | |
| 44 | 4 | `i_nlink` | 硬链接数（compact 版没有独立字段，靠 i_nb） |
| 48 | 16 | `i_reserved2` | |

> **关键差异**：extended 的 `i_size` 是 8 字节，因此后续字段整体后移；compact 用 4 字节 `i_size`。
> 判定：`i_format & EROFS_I_VERSION_MASK`（bit0）→ 0=compact(32B)/1=extended(64B)。

---

#### 2.4 xattr 相关

#### `struct erofs_xattr_ibody_header`（12 B）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 4 | `h_name_filter` | 位图，bit=1 表示该 xattr **不存在**（快速否定） |
| 4 | 1 | `h_shared_count` | 共享 xattr 个数 |
| 5 | 7 | `h_reserved2` | |
| 12 | 4×n | `h_shared_xattrs[]` | 共享 xattr 的 **id 数组**（4 B/项，柔性数组） |

#### `struct erofs_xattr_entry`（4 B + name + value）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 1 | `e_name_len` | 名字长度 |
| 1 | 1 | `e_name_index` | 名字空间索引（1=USER, 2/3=ACL, 4=TRUSTED, 6=SECURITY；bit7=长前缀） |
| 2 | 2 | `e_value_size` | 值长度 |
| 4 | — | `e_name[]` | 名字（柔性数组），随后是 value，整体按 4 B 对齐（`EROFS_XATTR_ALIGN`） |

---

#### 2.5 chunk 相关（datalayout = 4）

#### `union erofs_inode_i_u` 中的 `struct erofs_inode_chunk_info`（4 B）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 2 | `format` | **bit0-4 = chunk blkbits**（`chunksize = bs << (format & 0x1F)`）；bit5=`INDEXES`；bit6=`48BIT` |
| 2 | 2 | `reserved` | |

#### `struct erofs_inode_chunk_index`（8 B，每项对应一个 chunk）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 2 | `startblk_hi` | 起始块号高 16 位 |
| 2 | 2 | `device_id` | 后端设备 id（与 `device_id_mask` 掩码后编到地址 **48 位以上**） |
| 4 | 4 | `startblk_lo` | 起始块号低 32 位 |

---

#### 2.6 压缩相关（datalayout = 1 / 3）

#### `struct z_erofs_map_header`（8 B，压缩文件元数据区的头）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 4 | union：`h_fragmentoff` / {`h_reserved1`,`h_idata_size`} / `h_extents_lo` | fragment 在 packed inode 中的偏移 / **尾部内联数据编码长度** / extent 计数 LSB |
| 4 | 2 | `h_advise` | 建议位（大 pcluster、interlaced、extent 记录大小等） |
| 6 | 1 | `h_algorithmtype` | bit0-3=HEAD1 算法，bit4-7=HEAD2 算法 |
| 7 | 1 | `h_clusterbits` | bit0-3=逻辑 cluster 位数 - blkszbits；**bit7=整个文件打包进 packed inode**（fragment） |
| 6 | 2 | `h_extents_hi` | （同位置 union）extent 计数 MSB |

#### `struct z_erofs_lcluster_index`（8 B，noncompact/full 索引项）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 2 | `di_advise` | **低 2 位 = lcluster 类型**（0=PLAIN,1=HEAD1,2=NONHEAD,3=HEAD2） |
| 2 | 2 | `di_clusterofs` | 在 head pcluster 内解压起始偏移 |
| 4 | 4 | `di_u` | HEAD：`.blkaddr`（pcluster 起始块）；NONHEAD：`.delta[2]`（到 head / 下一 head 的距离） |

#### `struct z_erofs_extent`（32 B，extent 记录模式）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 4 | `plen` | 编码长度（bit27=partial，bit28-31=格式） |
| 4 | 4 | `pstart_lo` / 8:4 `pstart_hi` | 物理偏移 |
| 12 | 4 | `lstart_lo` / 16:4 `lstart_hi` | 逻辑偏移 |
| 20 | 12 | `reserved` | |

> **命名说明**：旧版内核里该结构叫 `z_erofs_vle_decompressed_index`，
> 在当前 7.3-rc5 中已改名为 **`z_erofs_lcluster_index`**（含义相同：逻辑 cluster → pcluster 的索引项）。

---

#### 2.7 目录与设备表

#### `struct erofs_dirent`（12 B，packed）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 8 | `nid` | 目标 inode 的 nid（bit63 = METABOX 标记） |
| 8 | 2 | `nameoff` | 文件名在目录块内的起始偏移 |
| 10 | 1 | `file_type` | 文件类型 |
| 11 | 1 | `reserved` | |

#### `struct erofs_deviceslot`（128 B，device table 项）

| 偏移 | 字节 | 字段 | 含义 |
|---|---|---|---|
| 0 | 64 | `tag` | digest(sha256) 等 |
| 64 | 4 | `blocks_lo` | 该设备总块数 LSB |
| 68 | 4 | `uniaddr_lo` | **统一地址空间起始块** LSB |
| 72 | 2 | `blocks_hi` | 块数 MSB |
| 74 | 2 | `uniaddr_hi` | 统一起始块 MSB |
| 76 | 52 | `reserved` | |

---

## 3. 五种 datalayout 分节解析

#### 判定通则

```
i_format (le16)
 bit 0      : 0 = compact inode(32B) / 1 = extended inode(64B)
 bit 1..3   : datalayout  (0..4)
 bit 4      : 非目录 compact inode: nlink==1 标志；目录: 是否省略 "." dirent
```

`datalayout = (le16_to_cpu(i_format) >> 1) & 0x07`

| 值 | 名称 | 数据本体位置 | 索引/元数据 |
|---|---|---|---|
| 0 | `FLAT_PLAIN` | data 区连续块 | `i_u.startblk` |
| 1 | `COMPRESSED_FULL` | data 区 pcluster | map_header + **8 B/项** lcluster 索引 |
| 2 | `FLAT_INLINE` | data 区连续块 + **尾块内联进元数据** | `i_u.startblk` + idata |
| 3 | `COMPRESSED_COMPACT` | data 区 pcluster | map_header + **2 B/项（摊销 4 B）** 索引 |
| 4 | `CHUNK_BASED` | data 区 / blob 设备 chunk | chunk index 数组（8 B 或 4 B/项） |

---

## 3.0 datalayout = 0 —— `FLAT_PLAIN`

#### 判定依据

- `i_format` bit0=0（compact）或 1（extended），`(i_format >> 1) & 7 == 0`
- `i_u` 解释为 **`startblk`**（起始块号）；`i_size` 为文件字节数
- **无 idata**（`idata_size = 0`），文件全部数据都在 data 区

#### ASCII 布局（示例：`big.bin`，i_size = 12288 = 3 块，startblk = 2）

```
 metadata area                                data area
 offset 1504 (nid 47)                          block 2      block 3      block 4
 +---------------------------+                +------------+------------+------------+
 | erofs_inode_compact(32B)  |                | data blk 0 | data blk 1 | data blk 2 |
 |  i_format = 0x00 ...      |   i_u = 2      | (文件 0~4095) | (4096~8191) | (8192~12287) |
 |  i_size  = 12288          |--------------> +------------+------------+------------+
 |  i_u.startblk_lo = 2      |                 ^            ^            ^
 +---------------------------+                 |            |            |
 + xattr ibody (若有)         |                 +-- startblk + 0/1/2 ----+
 +---------------------------+

 引用链路： inode(nid 47) --i_u.startblk=2--> erofs_pos(sb,2)=8192 --> 连续 3 块
```

若开启 48bit，`i_nb.startblk_hi` 提供高 16 位。

#### 关键说明

- 数据在 data 区**物理连续**，不需要 extent / 间接块 —— 这是 EROFS 相对 ext4/xfs 的核心简化。
- 读取映射（`fs/erofs/data.c: erofs_map_blocks`）走 flat 分支：

```c
pos = erofs_pos(sb, erofs_iblks(inode) - tailinline);   /* tailinline = 0 */
map->m_pa = erofs_pos(sb, vi->startblk) + map->m_la;
map->m_llen = pos - map->m_la;                          /* 到 pos 为止（含块尾 padding） */
```

- 实测：`big.bin nid=47`，`Layout: 0`，`Size: 12288`，`On-disk size: 12288`（无压缩收益）。

---

## 3.1 datalayout = 1 —— `COMPRESSED_FULL`（non-compact 索引）

#### 判定依据

- `(i_format >> 1) & 7 == 1`
- `i_u` 解释为 **`blocks`**（该文件占的总块数，供 stat 用），**不是**起始块
- 真正的块地址在元数据区的 **z_erofs_map_header + lcluster 索引**里
- 索引项 **8 B/项**（`z_erofs_lcluster_index`）

#### ASCII 布局

```
 metadata area
 iloc(nid)
 +---------------------------------------------------------------+
 | erofs_inode_compact/extended        (32 / 64 B)                |
 |   i_format: datalayout = 1                                     |
 |   i_u.blocks = 压缩后占用的总块数（仅统计用）                   |
 +---------------------------------------------------------------+
 | xattr ibody                        (xattr_isize 字节)          |
 +---------------------------------------------------------------+
 | ALIGN 到 8                                                     |
 +---------------------------------------------------------------+
 | z_erofs_map_header (8B)    @ ALIGN(inode_end, 8)               |
 |   h_algorithmtype / h_clusterbits / h_advise                   |
 +---------------------------------------------------------------+
 | (+8 B, Z_EROFS_FULL_INDEX_START 的额外偏移)                     |
 +---------------------------------------------------------------+
 | lcluster index[0] (8B)  di_advise|di_clusterofs|di_u.blkaddr   |---+
 | lcluster index[1] (8B)  ...                                     |   |
 | ...                                                             |   |
 +---------------------------------------------------------------+   |
                                                                      |
 data area                                                            |
 +----------------------------------------+                           |
 | pcluster 0 (lcluster index[0].blkaddr) |<--------------------------+
 |  编码后的压缩数据（可跨多块）           |
 +----------------------------------------+
 | pcluster 1 (index[1].blkaddr 或 delta)  |
 +----------------------------------------+
```

#### 索引区起始偏移（内核公式）

```c
/* fs/erofs/zmap.c: z_erofs_load_full_lcluster() */
pos = Z_EROFS_FULL_INDEX_START(erofs_iloc(inode) + inode_isize + xattr_isize)
      + lcn * sizeof(struct z_erofs_lcluster_index);
/* 其中 Z_EROFS_FULL_INDEX_START(end) = ALIGN(end, 8) + 8 + 8 */
```

#### 字段语义（`di_u` 的两副面孔）

| lcluster 类型（`di_advise & 3`） | `di_u` 解释 |
|---|---|
| `HEAD1` / `HEAD2` / `PLAIN` | `.blkaddr` = 该 pcluster 在 data 区的**起始块** |
| `NONHEAD` | `.delta[0]` = 到其 HEAD lcluster 的距离，`.delta[1]` = 到下一个 HEAD 的距离；`.delta[0]` 带 `Z_EROFS_LI_D0_CBLKCNT` 时表示压缩块数 |

#### 关键说明（pcluster）

- 压缩单位是 **pcluster**（physical cluster），可能聚合多个逻辑 cluster（`h_clusterbits`）。
- 解压后的数据再由 `di_clusterofs` 定位到逻辑偏移。
- 若 `h_clusterbits` **bit7** 置位（`Z_EROFS_FRAGMENT_INODE_BIT`）→ 整个文件被打包进 **packed inode**（`packed_nid`），偏移由 `h_fragmentoff` 给出（fragment 机制）。
- 尾部内联（ztailpacking）时，`h_idata_size` 给出内联在元数据里的编码长度。

---

## 3.2 datalayout = 2 —— `FLAT_INLINE`（tail-packing 尾块内联）

#### 判定依据

- `(i_format >> 1) & 7 == 2`
- `i_u` = `startblk`（指向 data 区的前 `iblks - 1` 块）
- **idata**：文件最后一个块的内容（不足一块的部分）**内联在元数据区**，紧跟 inode + xattr
- `idata_size = i_size % bs`（内核 `erofs_fill_inode` 中 `inode->idata_size`）

#### ASCII 布局（示例：`a.txt`，i_size = 7，1 块）

```
 metadata area
 iloc(nid 43) = 1376
 +--------------------------------------------------+
 | erofs_inode_compact (32B)                        |
 |   i_format = 0x04  → datalayout = (4>>1)&7 = 2   |
 |   i_size = 7                                     |
 |   i_u.startblk_lo = <blk>   (若 iblks>1 才有效)   |
 +--------------------------------------------------+
 | xattr ibody (若有)                                |
 +--------------------------------------------------+
 | idata：文件尾块内容（7 字节：hello-a）            |  ← 就在元数据区！
 +--------------------------------------------------+

  i_size=7 < bs → iblks=1 → pos = (1-1)*bs = 0
  ⇒ 全部走 inline 分支，startblk 可为 EROFS_NULL_ADDR
```

#### 引用链路（`erofs_map_blocks` 的 if / else）

```c
pos = erofs_pos(sb, erofs_iblks(inode) - tailinline);   /* tailinline = 1 */
if (map->m_la < pos) {          /* 数据区部分 */
        map->m_pa = erofs_pos(sb, vi->startblk) + map->m_la;
        map->m_llen = pos - map->m_la;
} else {                        /* inline 尾巴 */
        map->m_pa = erofs_iloc(inode) + vi->inode_isize
                  + vi->xattr_isize + erofs_blkoff(sb, map->m_la);
        map->m_llen = inode->i_size - map->m_la;
        map->m_flags |= EROFS_MAP_META;      /* 用 erofs_bread() 读元数据 */
        if (erofs_blkoff(sb, m_pa) + m_llen > bs) return -EFSCORRUPTED;  /* 禁止跨块 */
}
```

```
 inode --startblk--> [data blk 0][data blk 1]        (逻辑 [0, pos))
       --iloc+isize+xattr_isize--> [idata 尾块]      (逻辑 [pos, i_size))
```

#### 关键说明（tail-packing）

- 只有**最后一个块**的剩余部分会被内联（最多 1 块，禁止跨块 → 否则 `-EFSCORRUPTED`）。
- 好处：小文件完全不占 data 区，且读取时元数据页往往已在缓存，省一次 I/O。
- 实测：`a.txt nid=43`，`Layout: 2`，`Size: 7`；根目录 `nid=38` 也是 `Layout: 2`（dirent 数据内联）。

---

## 3.3 datalayout = 3 —— `COMPRESSED_COMPACT`（紧凑索引）

#### 判定依据

- `(i_format >> 1) & 7 == 3`
- 与布局 1 的**区别只在索引编码**：compact 用 **2 B/项**（每两个 lcluster 摊销一个 4 B 块地址），布局 1 用 8 B/项
- `i_u.blocks` = 总块数

#### ASCII 布局

```
 metadata area
 +--------------------------------------------------+
 | inode (compact/extended)                         |
 +--------------------------------------------------+
 | xattr ibody                                      |
 +--------------------------------------------------+
 | z_erofs_map_header (8B)  @ ALIGN(inode_end,8)    |   ← ebase = MAP_HEADER_END
 +--------------------------------------------------+
 | compact index 区（2 B/项，摊销）                  |
 |   lcluster0: 2B   lcluster1: 2B  (含 4B blkaddr)  |---+
 |   ...                                             |   |
 +--------------------------------------------------+   |
 | （ztailpacking 时）idata：编码后的尾部数据          |   |  h_idata_size 指定长度
 +--------------------------------------------------+   |
                                                        |
 data area                                              |
 +------------------------------------------+           |
 | pcluster（压缩数据，lz4 0padding 时放块尾）|<----------+
 +------------------------------------------+
```

#### 索引区起始偏移

```c
/* fs/erofs/zmap.c: z_erofs_load_compact_lcluster() */
ebase = Z_EROFS_MAP_HEADER_END(erofs_iloc(inode) + inode_isize + xattr_isize);
/* = ALIGN(inode_end, 8) + 8 */
```

> 与 full 模式对比：compact 的索引紧跟 map_header（+8），
> full 模式再多 8 B（`Z_EROFS_FULL_INDEX_START`）。

#### 关键说明

- 实测（`comp.erofs`）：`big.txt nid=43`、`f1 nid=46` 均为 **`Layout: 3`**；
  `Size: 20000` → `On-disk size: 4096`（压缩率 20.48%）。
- `feature_incompat` 含 `LZ4_0PADDING` → **pcluster 块内前面补 0，压缩数据放块尾**
  （实测 block 1 开头全 0，块尾才是 lz4 流 `2f 42 0a 02 00 ff...`）。
- extent 模式（`z_erofs_map_blocks_ext`）使用 `z_erofs_extent`（32 B/条），
  起始 `pos = round_up(MAP_HEADER_END(...), recsz)`，`recsz = 4 << ((h_advise >> 1) & 3)`。

---

## 3.4 datalayout = 4 —— `CHUNK_BASED`

#### 判定依据

- `(i_format >> 1) & 7 == 4`
- `i_u` 解释为 **`struct erofs_inode_chunk_info { format; reserved; }`**
  - `format & 0x1F` = chunk blkbits → `chunksize = bs << (format & 0x1F)`
  - `format & EROFS_CHUNK_FORMAT_INDEXES (0x20)` → 用 8 B `chunk_index`；否则用 **4 B 块地址数组**
  - `format & EROFS_CHUNK_FORMAT_48BIT (0x40)` → 48 位地址 + device_id
- `chunkbits = s_blocksize_bits + (chunkformat & 0x1F)`（内核 `inode.c`）

#### ASCII 布局（示例：chunksize = 64 KiB，文件 160 KiB → 3 chunk）

```
 metadata area
 iloc(nid 41)
 +----------------------------------------------------+
 | inode (32B)                                        |
 |   i_format: datalayout = 4                         |
 |   i_u.c.format = (blkbits<<0)|INDEXES|48BIT         |
 +----------------------------------------------------+
 | xattr ibody                                        |
 +----------------------------------------------------+
 | ALIGN(..., unit)                                   |  unit = 8 (INDEXES) 或 4
 +----------------------------------------------------+
 | chunk_index[0] (8B): startblk_hi|device_id|startblk_lo |---+
 | chunk_index[1] (8B)                                    |   |
 | chunk_index[2] (8B)                                    |   |
 +----------------------------------------------------+   |
                                                          |
 data area / blob 设备                                     |
 +-------------------------+  +----------------+  +--------+
 | chunk0 (64K)            |<-+ | chunk1 (64K)  |  | chunk2 |
 +-------------------------+    +----------------+  +--------+
    ^ device_id=1 时这块实际在 blob 设备（见多设备）
```

#### 索引定位（内核公式）

```c
/* fs/erofs/data.c: erofs_map_chunks() */
unit = (chunkformat & EROFS_CHUNK_FORMAT_INDEXES) ? sizeof(*idx) : EROFS_BLOCK_MAP_ENTRY_SIZE;
pos  = ALIGN(erofs_iloc(inode) + inode_isize + xattr_isize, unit) + unit * nr;   /* nr = m_la >> chunkbits */

/* 48 位 + 多设备：device_id 编到地址的 48 位以上 */
addr = ((u64)startblk_hi << 32 | startblk_lo) & addrmask;
if (addr != NULL_ADDR) addr |= (u64)(device_id & device_id_mask) << 48;
```

#### 关键说明

- chunk 之间**不要求连续**，可指向任意块，甚至**另一个设备**（`device_id`）。
- 去重（dedupe）依赖 chunk 粒度：相同 chunk 可共享同一块。
- 实测（`chunk.erofs`）：`data.bin nid=41`，**`Layout: 4`**，`feature_incompat` 含 `chunked_file`；  
  用 `--chunksize=65536` 生成；`inode_isize + xattr_isize` 之后便是 chunk index 数组。
- 多设备时（实测）：`device_id` **固定为 1**（`lib/blobchunk.c`），`extra_devices = 1`。

---

## 4. xattr 与 inline 数据在磁盘上的排列

#### inode 记录的三段结构

```
 iloc
 +----------------------------+
 | inode 主体 (inode_isize)    |  32 B (compact) 或 64 B (extended)
 +----------------------------+
 | xattr ibody (xattr_isize)   |  12 + (i_xattr_icount-1)*4 字节头 +
 |                             |  紧随其后的 inline xattr entries
 +----------------------------+
 | 布局相关的扩展区             |
 |  · datalayout 0/2 : idata   |  尾块内联数据（i_size % bs 字节）
 |  · datalayout 1/3 : zmap    |  map_header + lcluster 索引（+ idata）
 |  · datalayout 4   : chunk   |  chunk index 数组
 +----------------------------+
```

#### xattr ibody 的内部排列

```
 xattr_isize 区
 +--------------------------------+  offset 0
 | erofs_xattr_ibody_header (12B) |
 |   h_name_filter (4B)           |
 |   h_shared_count(1B) = 1        |
 |   h_reserved2[7]               |
 +--------------------------------+  offset 12
 | h_shared_xattrs[0] = <id> (4B) |  → 指向 shared xattr 区（xattr_blkaddr）
 +--------------------------------+  offset 16
 | erofs_xattr_entry #0           |  4B 头 + name + value（4B 对齐）
 | erofs_xattr_entry #1           |
 +--------------------------------+
```

- 实测：`i_xattr_icount = 1` 且为共享属性时，xattr 区正好 **16 B**（12 B 头 + 1 个 4 B shared id）。
- 共享 xattr 的**值**存放在 `xattr_blkaddr` 指向的 shared xattr 区，按 `xattr_offset = xattr_blkaddr*bs + 4*id` 定位。
- 实测（`xattr2.erofs`）：2000 B 的共享值落在 block 0 的 offset 1205 附近（dedupe 后只存一份）。

#### inline 数据（idata）的两种来源

| 场景 | idata 内容 | 长度来源 |
|---|---|---|
| `FLAT_INLINE`（2） | 文件最后一个块的原始字节 | `i_size % bs`（内核 `inode->idata_size`） |
| 压缩 + ztailpacking（1/3） | 尾部数据的**编码**结果 | `z_erofs_map_header.h_idata_size` |

#### 目录与 dirent

- 目录的数据块同样按目录 inode 的 datalayout 存放（常见为 `FLAT_INLINE`，小目录 dirent 直接内联）。  
- dirent 在块内**按名字字典序**排列，支持二分查找；块内布局为「前面 dirent 数组 + 后面文件名区」（头尾分离），`nameoff` 指向文件名。
- 实测根目录 `nid=38`，`Layout: 2`。

---

## 5. 五种 layout 对照总表

| | 0 FLAT_PLAIN | 1 COMPRESSED_FULL | 2 FLAT_INLINE | 3 COMPRESSED_COMPACT | 4 CHUNK_BASED |
|---|---|---|---|---|---|
| `i_u` 含义 | `startblk` | `blocks` | `startblk` | `blocks` | `chunk_info` |
| `i_size` | 文件字节数 | 文件**解压后**字节数 | 文件字节数 | 文件解压后字节数 | 文件字节数 |
| 数据在 data 区 | 连续块 | pcluster | 连续块 | pcluster | chunk（可跨设备） |
| 元数据区额外内容 | （xattr） | map_header + **8B/项**索引 | **idata 尾块** | map_header + **2B/项**索引 | chunk index 数组 |
| 索引项大小 | — | 8 B | — | 2 B（摊销 4 B） | 8 B 或 4 B |
| `idata` | 无 | ztailpacking 时有 | **有（尾块）** | ztailpacking 时有 | 无 |
| 尾部内联 | 否 | 可选 | **是** | 可选 | 否 |
| 跨设备能力 | 否 | 否 | 否 | 否 | **是（device_id）** |
| 实测出现 | `big.bin` Layout 0 | — | `a.txt`/root Layout 2 | `big.txt` Layout 3 | `data.bin` Layout 4 |

---

## 6. 速查：从文件偏移反推磁盘位置

```
 ① 逻辑偏移 la
      │
 ② erofs_map_blocks(inode, &map)          ← 按 datalayout 分派
      │  ├─ 0/2 : flat 分支 → m_pa = startblk*bs + la（或走 idata 分支）
      │  ├─ 1/3 : z_erofs_map_blocks_iter() → 查 lcluster 索引 → pcluster blkaddr
      │  └─ 4   : erofs_map_chunks() → 查 chunk index → chunk blkaddr (+device_id)
      │
 ③ erofs_map_dev(sb, &map)                ← 多设备时：统一地址 → 具体设备 + 设备内偏移
      │
 ④ 物理块 = m_pa >> 12，块内 = m_pa & 4095
```

> 相关源码入口：  
> `fs/erofs/data.c: erofs_map_blocks()` / `erofs_map_chunks()` / `erofs_map_dev()`  
> `fs/erofs/zmap.c: z_erofs_map_blocks_iter()` / `z_erofs_load_full_lcluster()` / `z_erofs_load_compact_lcluster()`  
> `fs/erofs/inode.c: erofs_fill_inode()`（`inode_isize` / `xattr_isize` / `idata_size` 的来源）

## 参考
[linux-stable (93f51579e7df)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)