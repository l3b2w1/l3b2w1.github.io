---
layout:     post
title:      EROFS chunk-based file addresing
subtitle:   EROFS chunk-based 文件寻址
date:       2026-10-12
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
---

# 23 · datalayout = 4（CHUNK_BASED）的寻址

> **基线**
> - 内核源码：`/home/linux/erofs/linux-stable`（Linux 7.3-rc5）—— `fs/erofs/data.c`
> - 用户态：`erofs-utils` 1.9.4 —— `lib/inode.c` / `lib/blobchunk.c` / `mkfs/main.c`
> - 统一假设：`bs = 4096`（`blkszbits = 12`）、小端序
>
> ⚠️ **函数名**：内核里叫 **`erofs_map_chunks`**（**带 s**），不是 `erofs_map_chunk`。
>
> **本文所有偏移与数值均为实测**（`dump.erofs` + `od`），不使用占位符。

---

## 0. 这个函数解决什么问题

`datalayout = 4`（`EROFS_INODE_CHUNK_BASED`）的文件，
**数据不再要求连续存放**——文件被切成固定大小的 **chunk**，每个 chunk 由 **chunk index 数组**里的一项
指向一个物理块（甚至可以指向**另一个设备**）。

`erofs_map_chunks()` 的任务：

```
给定逻辑地址 m_la
  ⇒ 算出它落在第几个 chunk
  ⇒ 找到该 chunk 的索引项（在元数据区）
  ⇒ 解出物理块地址（可能带 device_id）
  ⇒ 尽量向后合并连续的 chunk，一次映射尽量长
  ⇒ 回填 map->m_pa / m_llen / m_deviceid / m_flags
```

与 flat（0/2）的差别：flat 是"起始块 + 线性偏移"**一步算出**；chunk 是**先查索引、再算物理地址**的两段跳。

---

## 1. mkfs 侧：datalayout = 4 是怎么造出来的

#### 1.1 `--chunksize=N` → 全局 chunkbits

```c
/* mkfs/main.c:1268 */
cfg.c_chunkbits = ilog2(i);          /* N 必须是 2 的幂，否则报 "chunksize must be a power of two" */

/* 还有联动约束（mkfs/main.c:1509 / 1567 / 1582） */
if (cfg.c_blobdev_path && cfg.c_chunkbits < mkfs_blkszbits)   /* --blobdev 必须配 --chunksize */
if (cfg.c_chunkbits < mkfs_blkszbits)                          /* chunksize 必须大于块大小 */
```

#### 1.2 未压缩文件改走 chunk 路径

```c
/* erofs-utils/lib/inode.c:707  erofs_write_unencoded_file() */
if (cfg.c_chunkbits &&
    inode->datasource != EROFS_INODE_DATA_SOURCE_REBUILD_BLOB) {
        inode->u.chunkbits = cfg.c_chunkbits;
        /* chunk indexes when explicitly specified */
        inode->u.chunkformat = 0;
        if (cfg.c_force_chunkformat == FORCE_INODE_CHUNK_INDEXES)
                inode->u.chunkformat = EROFS_CHUNK_FORMAT_INDEXES;
        return erofs_blob_write_chunked_file(inode, fd, fpos);
}
```

⇒ 这解释了实测现象：**一旦给了 `--chunksize`，所有"未压缩"文件都变成 layout 4**
（连 5 字节的 `tiny.txt` 也是），于是 flat(0) 与 inline(2) 都不再出现。

#### 1.3 `erofs_blob_write_chunked_file()`：切块 + 去重 + 定格式

```c
/* lib/blobchunk.c:303 */

/* 全稀疏文件 → 直接用一个大 chunk 表示 */
if (lseek(fd, startoff, SEEK_DATA) < 0 && errno == ENXIO)
        chunkbits = ilog2(inode->i_size - 1) + 1;

chunksize = 1ULL << chunkbits;
count     = DIV_ROUND_UP(inode->i_size, chunksize);      /* chunk 个数 */

/* ★多设备必须用 8 B 索引（因为要带 device_id） */
if (sbi->extra_devices)
        inode->u.chunkformat |= EROFS_CHUNK_FORMAT_INDEXES;

unit = (chunkformat & EROFS_CHUNK_FORMAT_INDEXES) ?
        sizeof(struct erofs_inode_chunk_index) :          /* 8 */
        EROFS_BLOCK_MAP_ENTRY_SIZE;                       /* 4 */

inode->extent_isize = count * unit;                       /* 索引数组总字节数 */
inode->chunkindexes = malloc(count * max(sizeof(*idx), sizeof(void *)));  /* 先放 blobchunk 指针 */

for (pos = 0; pos < inode->i_size; pos += len) {
        /* 空洞区间 → 填 &erofs_holechunk（blkaddr = EROFS_NULL_ADDR） */
        /* 有数据 → erofs_blob_getchunk(sbi, chunkdata, len)
                    算 hash → 查 blob_hashmap ⇒ 命中则复用已有 chunk 的 blkaddr（★去重） */
        *(void **)idx++ = chunk;
}
inode->datalayout = EROFS_INODE_CHUNK_BASED;              /* ★落地为 4 */
return erofs_blob_mergechunks(inode, chunkbits, ...);     /* 合并小 chunk、定最终 chunkbits */
```

`erofs_blob_mergechunks()` 末尾把**相对值**写进格式字：

```c
inode->u.chunkformat = (chunkbits - sbi->blkszbits) | ...
```

⇒ **on-disk 存的是"相对 blkszbits 的差值"**，不是绝对位数。这是理解内核解码的关键。

#### 1.4 索引数组落盘

```c
/* lib/inode.c:908 —— 写完 inode 主体 + xattr 之后，紧跟着写 */
if (inode->extent_isize) {
        if (inode->datalayout == EROFS_INODE_CHUNK_BASED)
                ret = erofs_write_chunk_indexes(inode, ibmgr->vf, off);
                /* off = iloc + inode_isize + xattr_isize */
        else  /* 压缩元数据 */
                ...
}
```

```c
/* lib/blobchunk.c:175  erofs_write_chunk_indexes() */
addrmask     = _48bit ? BIT_ULL(48) - 1 : BIT_ULL(32) - 1;
startblk    &= addrmask;
idx.device_id   = cpu_to_le16(chunk->device_id);
idx.startblk_lo = cpu_to_le32(startblk);
idx.startblk_hi = cpu_to_le32(startblk >> 32);
DBG_BUGON(!_48bit && idx.startblk_hi);        /* 非 48bit 时高位必须为 0 */
/* unit == 4 时只写低 32 位（一个 __le32） */
```

> 另：inode 占槽计算处也体现了对齐 `lib/inode.c:1000`
> `if (inode->extent_isize) inodesize = roundup(inodesize, 8) + inode->extent_isize;`

#### 1.5 8 B chunk index（INDEXES 模式）的构造详解

##### 何时启用 8 B

| 方式 | 代码 | 说明 |
|---|---|---|
| 显式强制 | `mkfs/main.c:559`：`-Eforce-chunk-indexes` → `cfg.c_force_chunkformat = FORCE_INODE_CHUNK_INDEXES` | 用户指定 |
| **多设备自动** | `lib/blobchunk.c`：`if (sbi->extra_devices) inode->u.chunkformat \|= EROFS_CHUNK_FORMAT_INDEXES;` | 有 `--blobdev` 时**必然**启用 |

原因很直接：**只有 8 B 索引项里才有 `device_id` 字段**——要把 chunk 指向别的设备就必须用它。
（反向选项：`-Eforce-inode-blockmap` ⇒ `FORCE_INODE_BLOCK_MAP`，强制 4 B 数组。）

##### mkfs 的中间结构 `erofs_blobchunk`

```c
/* lib/blobchunk.c:18 */
struct erofs_blobchunk {
        union { struct hashmap_entry ent; struct list_head list; };
        char            sha256[32];      /* ★用于跨文件去重 */
        unsigned int    device_id;       /* ★8 B 索引才用得上 */
        union { erofs_off_t chunksize; erofs_off_t sourceoffset; };
        erofs_blk_t     blkaddr;
};
```

注意它**不是** on-disk 结构：`inode->chunkindexes` 先当作 `struct erofs_blobchunk *` 的**指针数组**使用，
落盘时才转换成真正的 `erofs_inode_chunk_index`。

##### `device_id` 从哪来

```c
/* lib/blobchunk.c  erofs_blob_getchunk() */
blkpos = lseek(blobfile, 0, SEEK_CUR);         /* chunk 写到 blobfile 的当前位置 */
DBG_BUGON(erofs_blkoff(sbi, blkpos));
if (sbi->extra_devices)
        chunk->device_id = 1;                   /* ★blob 设备 → 1 */
else
        chunk->device_id = 0;                   /* 主设备 → 0 */
chunk->blkaddr = erofs_blknr(sbi, blkpos);      /* 设备内块号 */
```

⇒ 与实测一致：**`device_id` 恒为 1**（mkfs 当前只支持一个 blob 设备）。

##### unit / extent_isize / 数组分配

```c
/* erofs_blob_write_chunked_file() */
if (sbi->extra_devices)
        inode->u.chunkformat |= EROFS_CHUNK_FORMAT_INDEXES;
unit = (chunkformat & EROFS_CHUNK_FORMAT_INDEXES) ?
        sizeof(struct erofs_inode_chunk_index) :    /* 8 */
        EROFS_BLOCK_MAP_ENTRY_SIZE;                 /* 4 */
inode->extent_isize = count * unit;                 /* 索引数组总字节数 */
inode->chunkindexes = malloc(count * max(sizeof(*idx), sizeof(void *)));
        /* 8 B 模式：max(8, 8) = 8；4 B 模式：max(8, 4) = 8（指针本身也是 8 B） */
```

##### 48BIT 位的判定（与 INDEXES 相互独立）

```c
/* lib/blobchunk.c:138  erofs_inode_fixup_chunkformat() */
_48bit = inode->u.chunkformat & EROFS_CHUNK_FORMAT_48BIT;
if (_48bit) return;
for (每个 chunk) {
        if (chunk->blkaddr == EROFS_NULL_ADDR) continue;
        if (chunk->device_id) {
                if (chunk->blkaddr > UINT32_MAX)                { _48bit = true; break; }
        } else if (remapped_base + chunk->blkaddr > UINT32_MAX)  { _48bit = true; break; }
}
if (_48bit) inode->u.chunkformat |= EROFS_CHUNK_FORMAT_48BIT;
```

⇒ 只有块地址真超过 32 位时才补置 48BIT。

##### 填索引项：8 B 与 4 B 的写入分支

```c
/* lib/blobchunk.c:175  erofs_write_chunk_indexes() */
addrmask     = _48bit ? BIT_ULL(48) - 1 : BIT_ULL(32) - 1;
startblk    &= addrmask;
idx.device_id   = cpu_to_le16(chunk->device_id);
idx.startblk_lo = cpu_to_le32(startblk);
idx.startblk_hi = cpu_to_le32(startblk >> 32);   /* 字段是 __le16，实际只写入低 16 位 */
DBG_BUGON(!_48bit && idx.startblk_hi);           /* 非 48bit 时高位必须为 0 */
...
if (unit == EROFS_BLOCK_MAP_ENTRY_SIZE)
        memcpy(inode->chunkindexes + dst, &idx.startblk_lo, unit);  /* 4 B：只写低 32 位 */
else
        memcpy(inode->chunkindexes + dst, &idx, sizeof(idx));       /* 8 B：写整个结构 */
...
off = roundup(off, unit);                                           /* ★按 unit 对齐 */
return erofs_io_pwrite(vf, inode->chunkindexes, off, inode->extent_isize);
```

> 小细节：`startblk_hi` 在结构体里是 `__le16`（2 B），上面用 `cpu_to_le32()` 赋值会被截断为低 16 位；
> 小端序下等价于 `cpu_to_le16()`，结果正确。于是 `startblk_hi(16) + startblk_lo(32) = 48 位`块地址，
> 正好对应 48BIT 模式。

##### on-disk 8 B 索引项的字节布局

```
 相对偏移   0        2        4              8
          +--------+--------+---------------+
          |startblk| device |  startblk_lo  |
          |  _hi   |  _id   |    (le32)     |
          +--------+--------+---------------+
            le16     le16     le32
          \_______ 48 位块地址 _______/
                   ↑
            device_id 单独占 2 B（不参与块地址）
```

##### 实测对照：多设备（8 B）vs 单设备（4 B）

| | 多设备 `md.erofs` | 单设备 `chunk.erofs` |
|---|---|---|
| mkfs 选项 | `-b4096 --chunksize=65536 -zlz4 --blobdev=blob.img` | `-b4096 --chunksize=65536` |
| `incompat` | `lz4_0padding chunked_file device_table` | `chunked_file` |
| inode 版本 | **extended（64 B）** | compact（32 B） |
| 文件 | `/big.bin` nid=45，**layout 4** | `/big.txt` nid=40，**layout 4** |
| `chunkformat` | **`0x0024`** = 4(delta) **\| 0x20(INDEXES)** | `0x0004` = 4(delta) |
| unit | **8** | 4 |
| 索引起点 | `iloc(1440) + 64(inode_isize) + 0(xattr)` ⇒ **1504** | `iloc(1280) + 32 + 0` ⇒ **1312** |
| 索引项内容 | `00 00 01 00 00 00 00 00` ⇒ `device_id=1, blkaddr=0` | `01 00 00 00` ⇒ `blkaddr=1` |
| 数据落点 | `blob.img` 偏移 0（与 `src/big.bin` 前 16 B 逐字节一致 ✓） | 主镜像 block 1 |

⚠️ **inode 版本会影响索引起点**：compact 时 `iloc + 32`、extended 时 `iloc + 64`。
`md.erofs` 用 extended 是因为文件 mtime ≠ 镜像 epoch（`lib/inode.c:1203` 的判定），
不是因为 chunk —— 这两者是独立的选择。

##### 与内核解码的对称关系

mkfs 写进去的三项，被内核 `erofs_map_chunks()` 的 8 B 分支原样读回：

```c
addr = ((startblk_hi << 32) | startblk_lo) & addrmask;   /* 48/32 位块地址 */
if (addr ^ (EROFS_NULL_ADDR & addrmask))
        addr |= (device_id & device_id_mask) << 48;      /* 还原 device_id */
```

写与读完全对称 ✓

---

## 2. on-disk 布局：chunk index 数组在哪、长什么样

#### 2.1 布局图

```
 iloc = meta_blkaddr*bs + nid*32
        │
        ▼
 +--------------------------------+  ← iloc
 | erofs_inode_compact    (32 B)  |
 |   i_format  bit1-3 = 4         |  ⇒ datalayout = 4 CHUNK_BASED
 |   i_u 解释为 chunk_info：      |
 |     c.format (le16) @+16       |  ← chunkbits 差值 + INDEXES/48BIT 位
 |     c.reserved     @+18        |
 +--------------------------------+
 | xattr ibody    (xattr_isize)   |  0 或 12+(n-1)*4
 +--------------------------------+
 | ALIGN(..., unit)               |  ← 按索引项大小对齐（4 或 8）
 +--------------------------------+
 | chunk index[0]                 |  unit=8: device_id/startblk_hi/startblk_lo
 | chunk index[1]                 |  unit=4: 仅一个 __le32 块地址
 | ...                            |
 | chunk index[count-1]           |  count = ceil(i_size / chunksize)
 +--------------------------------+
        │  解码后
        ▼
   data area（或 blob 设备的）chunk 数据
```

#### 2.2 `unit` 的选择：8 B 还是 4 B

| 条件 | unit | 索引项结构 | 能否带 device_id |
|---|---|---|---|
| `chunkformat & EROFS_CHUNK_FORMAT_INDEXES (0x20)` | **8** | `erofs_inode_chunk_index` | ✅ 能 |
| 否则 | **4** | 裸 `__le32` 块地址数组 | ❌ 不能 |

⇒ **多设备镜像必然是 8 B**（`sbi->extra_devices` 时 mkfs 强制开 INDEXES）。

#### 2.3 `chunkformat` 的三个位域

| 位 | 名称 | 含义 |
|---|---|---|
| bit 0–4 | `EROFS_CHUNK_FORMAT_BLKBITS_MASK (0x1F)` | **chunksize = bs << 该值**（相对值！） |
| bit 5 | `EROFS_CHUNK_FORMAT_INDEXES (0x20)` | 用 8 B 索引项（可带 device_id） |
| bit 6 | `EROFS_CHUNK_FORMAT_48BIT (0x40)` | 块地址为 48 位（>4 GiB 镜像） |

内核读取端还原（`fs/erofs/inode.c:208`）：

```c
vi->chunkformat = le16_to_cpu(copied.i_u.c.format);
if (vi->chunkformat & ~EROFS_CHUNK_FORMAT_ALL) { ... -EOPNOTSUPP ... }
vi->chunkbits = sb->s_blocksize_bits +
        (vi->chunkformat & EROFS_CHUNK_FORMAT_BLKBITS_MASK);
```

#### 2.4 实测：chunk.erofs 的 on-disk 字节

镜像：`/home/linux/erofs/tmp-isize/chunk.erofs`（`mkfs.erofs -b4096 --chunksize=65536`），
文件 `/big.txt`：`nid=40`、`i_size=20000`、**layout=4**。

```
iloc = 40*32 = 1280

i_u（chunk_info）@1296 = 04 00 00 00
    ⇒ chunkformat = 0x0004
        低 5 位 = 4        ⇒ chunksize = 4096 << 4 = 65536 ✓
        无 INDEXES(0x20)   ⇒ unit = 4
        无 48BIT(0x40)     ⇒ addrmask = BIT_ULL(32)-1

chunk index 起点 = ALIGN(1280 + 32(inode_isize) + 0(xattr_isize), 4) = 1312

@1312: 01 00 00 00        → le32 = 1   ⇒ 该 chunk 数据在 block 1
```

（chunksize 65536 > i_size 20000 ⇒ `count = 1` ⇒ 索引数组只有 4 B。）

---

## 3. 内核 `erofs_map_chunks()` 逐段解析

> 位置：`fs/erofs/data.c:87`；由 `erofs_map_blocks()` 在
> `vi->datalayout == EROFS_INODE_CHUNK_BASED` 时调用。

#### 3.1 完整代码

```c
static int erofs_map_chunks(struct inode *inode, struct erofs_map_blocks *map)
{
        struct erofs_buf buf = __EROFS_BUF_INITIALIZER;
        struct super_block *sb = inode->i_sb;
        struct erofs_inode *vi = EROFS_I(inode);
        struct erofs_inode_chunk_index *idx;
        unsigned int unit = vi->chunkformat & EROFS_CHUNK_FORMAT_INDEXES ?
                sizeof(*idx) : EROFS_BLOCK_MAP_ENTRY_SIZE;
        erofs_blk_t addrmask = (vi->chunkformat & EROFS_CHUNK_FORMAT_48BIT) ?
                BIT_ULL(48) - 1 : BIT_ULL(32) - 1;
        u64 nr = map->m_la >> vi->chunkbits, chunksize = 1ULL << vi->chunkbits;
        erofs_off_t pos = ALIGN(erofs_iloc(inode) + vi->inode_isize +
                                vi->xattr_isize, unit) + unit * nr;
        /* m_llen will be clamped to EOF in the end */
        erofs_off_t endpos = round_up(pos + 1, sb->s_blocksize);
        u64 last, addr;

        idx = erofs_read_metabuf(&buf, sb, pos, erofs_inode_in_metabox(inode));
        if (IS_ERR(idx))
                return PTR_ERR(idx);

        map->m_la = nr << vi->chunkbits;
        map->m_llen = 0;
        nr = 0;
        do {
                if (unit == EROFS_BLOCK_MAP_ENTRY_SIZE) {
                        addr = le32_to_cpu(((__le32 *)idx)[nr]);
                        if (addr == (u32)EROFS_NULL_ADDR)
                                addr = EROFS_NULL_ADDR;
                } else {
                        addr = (((u64)le16_to_cpu(idx[nr].startblk_hi) << 32) |
                                le32_to_cpu(idx[nr].startblk_lo)) & addrmask;
                        if (addr ^ (EROFS_NULL_ADDR & addrmask))
                                addr |= (u64)(le16_to_cpu(idx[nr].device_id) &
                                        EROFS_SB(sb)->device_id_mask) << 48;
                        else
                                addr = EROFS_NULL_ADDR;
                }
                if (!nr) {
                        last = addr;
                        continue;
                }
                /* expand and account the prior chunk here */
                map->m_llen += chunksize;
                if (last != EROFS_NULL_ADDR)
                        last += erofs_blknr(sb, chunksize);
        } while (addr == last && pos + (++nr) * unit < endpos);

        if (last != EROFS_NULL_ADDR) {
                map->m_pa = erofs_pos(sb, last & addrmask) - map->m_llen;
                map->m_deviceid = last >> 48;
                map->m_flags = EROFS_MAP_MAPPED;
        }
        if (addr == last)
                map->m_llen += chunksize;
        map->m_llen = min_t(erofs_off_t, map->m_llen,
                        round_up(inode->i_size - map->m_la, sb->s_blocksize));
        erofs_put_metabuf(&buf);
        return 0;
}
```

#### 3.2 ① 定参数、算索引项地址

```
nr   = m_la >> chunkbits                          → 第几个 chunk
pos  = ALIGN(iloc + inode_isize + xattr_isize, unit) + unit * nr
endpos = round_up(pos + 1, bs)                    → ★不允许读穿当前元数据块
idx  = erofs_read_metabuf(&buf, sb, pos, in_metabox)     ← 元数据通道
m_la = nr << chunkbits                            → 逻辑地址对齐到 chunk 起点
```

`ALIGN(..., unit)` 与 mkfs 的落盘对齐一致（mkfs 侧 `roundup(..., 8)`，而 8 是 4 的倍数 ⇒ 两边同点）。

#### ⚠️ 澄清：`idx` 到底指向第几个 chunk index？

**指向第 `nr` 个（绝对序号 = `m_la >> chunkbits`）那一项，不是第 0 个。**

理由：`pos` 里已经加了 `unit * nr`；而 `erofs_read_metabuf()` → `erofs_bread()` 返回的正是
「所在元数据块内、`offset` 处」的指针（`buf->base + (offset & (bs-1))`），所以 `idx` 落在第 `nr` 项上。

更要注意的是——**变量 `nr` 在这里换了一次含义**：

| 阶段 | `nr` 的含义 | 取值 |
|---|---|---|
| 算 `pos` 时 | **绝对序号**（目标 chunk 是第几个） | `m_la >> chunkbits` |
| 循环里（执行 `nr = 0` 之后） | **相对 `idx` 的偏移量** | 0, 1, 2 … |

⇒ 循环中的 `idx[nr]` 实际访问的是**绝对第 (原 nr + nr) 项**。这是读这段代码最容易看错的地方。

**多 chunk 例子**（`chunksize = 4096`、`i_size = 20000` ⇒ `count = 5`、`unit = 4`，数组起点 1312）：

```
m_la = 12288 ⇒ 原 nr = 12288 >> 12 = 3
pos  = 1312 + 4*3 = 1324        ⇒ idx 指向 @1324（第 3 项）
循环 nr=0 → 读 @1324（绝对第 3 项）
     nr=1 → 读 @1328（绝对第 4 项）
```

> 注：本文 §3.6 那个实测例（`/big.txt`，`chunksize=65536` ⇒ 只有 1 个 chunk，`nr = 0`）
> 中 `idx` 恰好也落在第 0 项，**特殊情形下看不出差别**，不要据此认为它总是指向第 0 项。

#### 3.3 ② 解码索引项（含 device_id）

**4 B 模式**：直接取 `__le32`，等于 `(u32)EROFS_NULL_ADDR` 时判为洞。

**8 B 模式**（关键）：

```c
addr = ((startblk_hi << 32) | startblk_lo) & addrmask;      /* 块地址只占 48/32 位 */
if (addr ^ (EROFS_NULL_ADDR & addrmask))                    /* 非洞 */
        addr |= (device_id & device_id_mask) << 48;          /* ★device_id 编到 bit48 以上 */
else
        addr = EROFS_NULL_ADDR;
```

⇒ **索引项只有 48 位存块地址，高 16 位（bit48–63）用来带 `device_id`**。
`device_id_mask = roundup_pow_of_two(extra_devices + 1) - 1`（`super.c`）。

#### 3.4 ③ 向后合并连续 chunk

```c
do {
        解码 addr
        if (!nr) { last = addr; continue; }        /* 第一项只作为基准 */
        map->m_llen += chunksize;                  /* 计入前一个 chunk */
        if (last != NULL_ADDR) last += erofs_blknr(sb, chunksize);  /* 物理地址推进 */
} while (addr == last && pos + (++nr) * unit < endpos);
```

- `addr == last`：下一个 chunk 物理地址正好接上 ⇒ 连续，继续扩。
- `< endpos`：**绝不读穿当前元数据块**（索引数组跨块时，本次只映射块内部分，剩下的下次再映射）。

#### 3.5 ④ 回填结果（★回退技巧）+ clamp

```c
if (last != EROFS_NULL_ADDR) {
        map->m_pa = erofs_pos(sb, last & addrmask) - map->m_llen;   /* ★回退到起点 */
        map->m_deviceid = last >> 48;                                /* 取出设备号 */
        map->m_flags = EROFS_MAP_MAPPED;
}
map->m_llen = min_t(erofs_off_t, map->m_llen,
        round_up(inode->i_size - map->m_la, sb->s_blocksize));       /* clamp 到 EOF */
```

因为循环里 `last` 已一路往前推进，所以要用 `erofs_pos(last) - m_llen` **回退**到这段映射的起始物理地址；
`last & addrmask` 把 device_id 剥掉只留块地址，`last >> 48` 反过来取出设备号。

#### 3.6 端到端实例（真实数值，可与 `od` 逐字节比对）

```
输入：inode = /big.txt (nid=40, i_size=20000, chunksize=65536, unit=4)

m_la = 0
→ nr    = 0 >> 16 = 0
→ pos   = ALIGN(1280+32+0, 4) + 4*0 = 1312
→ endpos= round_up(1312+1, 4096) = 4096

迭代1: 读 @1312 = le32 = 1 ；nr==0 ⇒ last = 1，continue
while: addr(1)==last(1) ✓ 且 1312 + 1*4 = 1316 < 4096 ✓ ⇒ 继续

迭代2: 读 @1316 = 00 00 00 00 → addr = 0 ；nr!=0 ⇒
       m_llen += 65536 ⇒ 65536
       last   += erofs_blknr(4096, 65536)=16 ⇒ 1+16 = 17
while: addr(0) != last(17) ⇒ 退出

回填：
  m_pa      = erofs_pos(17 & 0xffffffff) - 65536 = 17*4096 - 65536 = 4096   ← block 1 ✓
  m_deviceid= 17 >> 48 = 0
  m_flags   = EROFS_MAP_MAPPED
  clamp: m_llen = min(65536, round_up(20000-0, 4096)=20480) = 20480
```

```
 逻辑 [0 , 20000)                      物理 block 1 起，20480 B（按块向上取整）
      │                                      ▲
      │  nr = 0                              │ m_pa = 4096
      ▼                                      │
 chunk index[0] @1312 = 01 00 00 00 ─────────┘
 （索引项值 = 1 ⇒ block 1）
```

与 `od -j 1312` 看到的 `01 00 00 00` 完全一致 ✓

---

## 4. 六个要点小结

| 要点 | 说明 |
|---|---|
| **unit 选 8 还是 4** | 由 `chunkformat & 0x20`（INDEXES）决定；**多设备时 mkfs 强制 INDEXES**（要带 device_id） |
| **chunkbits 是相对值** | on-disk 存 `chunkbits - blkszbits`；内核还原为 `blkszbits + (chunkformat & 0x1F)` |
| **device_id 藏在高 16 位** | 块地址只用低 48 位，`device_id << 48` 与之拼成 u64；`>>48` 取回、`& addrmask` 剥离 |
| **一次映射尽量长** | 只要 chunk 物理连续就合并；受 `endpos`（不跨元数据块）与 `i_size`（clamp）双重限制 |
| **hole 处理** | `addr == NULL_ADDR` ⇒ 不置 `MAPPED`，上层按洞读零 |
| **回退技巧** | `m_pa = erofs_pos(last) - m_llen`（因 `last` 在循环中已推进） |

> 补充：内核这个 `do-while` 会**多读一个索引项**（本例读到了数组之后的字节）。
> 它靠 `endpos` 限制在同一元数据块内，且值不等于 `last` 就停止扩展——只读不写，配合末尾 clamp，是安全的。

---

## 5. 关键代码引用位置

| 环节 | 位置 |
|---|---|
| chunk 映射主函数 | `fs/erofs/data.c: erofs_map_chunks()` |
| 分派（按 datalayout） | `fs/erofs/data.c: erofs_map_blocks()` |
| 多设备：统一地址 → 具体设备 | `fs/erofs/data.c: erofs_map_dev()` / `erofs_fill_from_devinfo()` |
| 读取端解析 chunkformat/chunkbits | `fs/erofs/inode.c`（`vi->chunkformat` / `vi->chunkbits`） |
| mkfs：`--chunksize` → `c_chunkbits` | `erofs-utils/mkfs/main.c:1268`（含 1509 / 1567 / 1582 的约束） |
| mkfs：改走 chunk 路径 | `erofs-utils/lib/inode.c: erofs_write_unencoded_file()` |
| mkfs：切块 + 去重 + 定格式 | `erofs-utils/lib/blobchunk.c: erofs_blob_write_chunked_file()`、`erofs_blob_getchunk()`、`erofs_blob_mergechunks()` |
| mkfs：索引数组落盘 | `erofs-utils/lib/inode.c:908` → `lib/blobchunk.c: erofs_write_chunk_indexes()` |
| 结构体定义 | `fs/erofs/erofs_fs.h`：`erofs_inode_chunk_info`、`erofs_inode_chunk_index` |
| 格式位定义 | `fs/erofs/erofs_fs.h`：`EROFS_CHUNK_FORMAT_BLKBITS_MASK / INDEXES / 48BIT`；`EROFS_BLOCK_MAP_ENTRY_SIZE` |


## 参考
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)  
[erofs-utils(1.9.4)](https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git)  
[linux-stable (93f51579e7df)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  