---
layout:     post
title:      EROFS mount and metabuf
subtitle:   EROFS 挂载与元数据原语
date:       2026-09-07
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---


# 阶段 3：非压缩读路径

> 本章会做一件很爽的事：把阶段 1 里 `dump.erofs` 看到的现象，
> 和产生它的那段代码**一一对上**。


## 本阶段目标

读完这一章，你应该能够：

1. 说出 EROFS 的读入口有哪几个，以及它们为什么都走 iomap
2. **画出一次非压缩读从 `read()` 到设备的完整调用链**
3. 读懂 `erofs_map_blocks()`，并解释它如何对应阶段 1 的实测 extent
4. 解释 chunk-based 映射里"设备号编入地址高 16 位"的设计
5. 说清 `erofs_map_dev()` 怎么确定数据在哪台设备上
6. 解释内联数据（tail-packing）在运行时是怎么被读出来的
7. 知道 fileio 后端与块设备后端的差别

## 3.1 先回顾：阶段 1 留下的那个悬念

阶段 1 里我们看到 `big.bin`（100KB，Layout 2）有两个 extent：

```
 Ext:   logical offset   |  length :     physical offset    |  length
   0:        0..   98304 |   98304 :       8192..    106496 |   98304
   1:    98304..  100000 |    1696 :       1264..      2960 |    1696
```

**为什么一个文件会分成两段？**   
因为前 98304 字节在正常数据块，
而最后 1696 字节不足一块，被 mkfs 内联到了 inode 后面（物理偏移 1264，在元数据区）。

**这两段在代码里对应两个不同的分支**——本章就能看到。带着这个问题往下读。

## 3.2 EROFS 的四个入口，全都走 iomap

EROFS 现在的读路径**全部**通过 iomap 框架。入口有四个，都在 `data.c`：

| 入口 | 位置 | 什么时候被调用 |
|---|---|---|
| `erofs_read_folio` | `data.c` | 单页读（缓存未命中时） |
| `erofs_readahead` | `data.c` 附近 | 预读（内核猜测你接下来要读） |
| `erofs_file_read_iter` | `data.c` | 直接 IO（`O_DIRECT`） |
| `erofs_fiemap` / `erofs_bmap` | `data.c` / `:444` | 查询用（FIEMAP、FIBMAP） |

它们都通过 `erofs_iomap_ops`（`data.c`）把工作交给 iomap 框架。

**这意味着什么？** EROFS 只需要实现"翻译"这一件事，
预读策略、IO 提交、DAX、FIEMAP 这些统统由 iomap 框架负责。  
这也是 EROFS 代码量小的重要原因。

> 如果你按老教程去找 `erofs_readpage()`，会找不到——
> 不是你漏了，是接口从 `->readpage` 换成了 iomap。

## 3.3 ⭐ `erofs_iomap_begin()`：本阶段的核心

![非压缩读路径](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-08-erofs-07-noncompressed-read-path.svg)

`erofs_iomap_begin`（`data.c`）是"翻译"这件事的入口。
它做的事是：**拿一个文件偏移，返回一个填好的 `struct iomap`**。

流程只有四步：

```c
static int erofs_iomap_begin(struct inode *inode, loff_t offset, loff_t length,
                unsigned int flags, struct iomap *iomap, struct iomap *srcmap)
{
        ...
        map.m_la = offset;                      /* :310 要翻译的逻辑地址 */
        map.m_llen = length;
        ret = erofs_map_blocks(realinode, &map); /* :312 调 EROFS 自己的映射 */
        if (ret < 0)
                return ret;

        iomap->offset = map.m_la;               /* :316 */
        iomap->length = map.m_llen;
        iomap->flags = 0;
        iomap->addr = IOMAP_NULL_ADDR;

        if (!(map.m_flags & EROFS_MAP_MAPPED)) { /* :320 */
                iomap->type = IOMAP_HOLE;        /* 空洞：没有对应磁盘块 */
                return 0;
        }
        ...
```

**第 1 步：调 `erofs_map_blocks()` 拿到映射结果**（3.4 节细讲）

**第 2 步：没映射 → 空洞**

`IOMAP_HOLE` 表示"这段文件范围没有对应的磁盘数据"。
读它会得到全 0，且不产生任何 IO。

**第 3 步：确定设备**（`:325-341`，3.6 节细讲）

**第 4 步：按标志决定 iomap 类型**（`:343-360`）

```c
        if (map.m_flags & EROFS_MAP_META) {
                iomap->type = IOMAP_INLINE;     /* :344 内联数据 */
                ...
        } else {
                iomap->type = IOMAP_MAPPED;     /* :359 正常映射 */
        }
```

三种类型对应三种情况：

| iomap->type | 含义 | 谁产生的 |
|---|---|---|
| `IOMAP_HOLE` | 空洞，读出来是 0 | `map.m_flags` 无 `MAPPED` |
| `IOMAP_INLINE` | 数据在元数据区（内联） | `map.m_flags` 有 `META` |
| `IOMAP_MAPPED` | 数据在正常磁盘块 | 其余情况 |  

## 3.4 ⭐ `erofs_map_blocks()`：与阶段 1 实测完美对应

`erofs_map_blocks`（`data.c`）回答的问题：
**"文件偏移 `m_la` 处的数据，在文件系统内的哪个物理地址？"**

注意它还**没有**确定是哪台设备——那是 `erofs_map_dev()` 的事（3.6 节）。

```c
int erofs_map_blocks(struct inode *inode, struct erofs_map_blocks *map)
{
        ...
        bool tailinline = (vi->datalayout == EROFS_INODE_FLAT_INLINE);   /* :164 */
        ...
        if (map->m_la >= inode->i_size)                                   /* :171 */
                goto out;
        if (vi->datalayout == EROFS_INODE_CHUNK_BASED) {                  /* :173 */
                err = erofs_map_chunks(inode, map);
        } else if (tailinline || vi->startblk != EROFS_NULL_ADDR) {       /* :175 */
                pos = erofs_pos(sb, erofs_iblks(inode) - tailinline);     /* :176 */
                map->m_flags = EROFS_MAP_MAPPED;
                if (map->m_la < pos) {                                    /* :178 */
                        map->m_pa = erofs_pos(sb, vi->startblk) + map->m_la;
                        map->m_llen = pos - map->m_la;
                } else {                                                  /* :181 */
                        map->m_pa = erofs_iloc(inode) + vi->inode_isize +
                                vi->xattr_isize + erofs_blkoff(sb, map->m_la);
                        map->m_llen = inode->i_size - map->m_la;
                        map->m_flags |= EROFS_MAP_META;                   /* :185 */
                        ...
                }
        }
```

### 分支一：chunk-based

`datalayout == 4` 时走 `erofs_map_chunks()`（`data.c`），见 3.5 节。

### 分支二：flat 布局（PLAIN / INLINE）

关键是 `data.c` 那个判断：

```c
if (map->m_la < pos) {
        /* 主体部分：在独立数据块里 */
} else {
        /* 尾部部分：内联在 inode 后面 */
}
```

**这就是阶段 1 那个悬念的答案！**

`pos` 是"主体数据的末尾"（`data.c`）：

```c
pos = erofs_pos(sb, erofs_iblks(inode) - tailinline);
```

`erofs_iblks(inode)` 是文件占用的块数；
**减去 `tailinline`**（0 或 1）是因为：如果有内联尾部，最后那块不算主体。

用 `big.bin` 的真实数字验证：

```
文件大小 100000 字节，块 4096
块数 = ceil(100000 / 4096) = 25 块
tailinline = 1（是 FLAT_INLINE）
pos = (25 - 1) × 4096 = 98304          ← 正好是第一个 extent 的边界！

读偏移 0      → 0 < 98304      → 走主体分支，m_pa = startblk 转字节
读偏移 99000  → 99000 >= 98304 → 走尾部分支，m_pa = inode 后面
```

**与 `dump.erofs` 的输出完全吻合**：第一个 extent 到 98304 为止，
第二个 extent 从 98304 开始，长度 1696（= 100000 - 98304）。

### 尾部分支的细节

```c
map->m_pa = erofs_iloc(inode) + vi->inode_isize +
        vi->xattr_isize + erofs_blkoff(sb, map->m_la);      /* :182-183 */
map->m_flags |= EROFS_MAP_META;                              /* :185 */
```

拆解：

```
m_pa = inode 在磁盘的位置
     + inode 结构本身的大小
     + xattr 区域的大小
     + 块内偏移
```

即"**inode 后面的那块地方**"——正是 mkfs 把尾部数据塞进去的位置。

`EROFS_MAP_META` 标志很关键：它告诉后续代码"这段数据在元数据区，不在数据区"，
于是 iomap 走 `IOMAP_INLINE` 而不是 `IOMAP_MAPPED`。

> 阶段 1 里 big.bin 尾部的物理偏移是 1264。  
> 用上面的公式：nid=38 → erofs_iloc = 38 × 32 = 1216，
> 加 inode_isize(32) = 1248，加 xattr_isize(16) = 1264。**完全对上。**

## 3.5 chunk-based：设备号编进地址高 16 位

![chunk 设备号编码](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-08-erofs-08-chunk-deviceid.svg)

chunk-based 文件（datalayout 4）的映射走 `erofs_map_chunks()`（`data.c`）。

它的特殊之处在于：需要同时表达"**哪个设备**"和"**哪个块**"。
做法是把 64 位地址劈成两半：

```c
/* 编码：data.c */
if (addr ^ (EROFS_NULL_ADDR & addrmask))
        addr |= (u64)(le16_to_cpu(idx[nr].device_id) &
                EROFS_SB(sb)->device_id_mask) << 48;
else
        addr = EROFS_NULL_ADDR;

/* 解码：data.c */
map->m_pa = erofs_pos(sb, last & addrmask) - map->m_llen;
map->m_deviceid = last >> 48;
```

```
 63              48 47                                       0
┌─────────────────┬───────────────────────────────────────────┐
│    device_id    │              物理块地址                    │
│    （16 位）     │               （48 位）                    │
└─────────────────┴───────────────────────────────────────────┘
```

**为什么这么设计？**

"逻辑偏移 → 物理位置"这个映射函数的返回值里，通常只有"地址"一个字段。  
多设备支持是后来加的，不想改接口签名，就把设备号塞进高位。

- 代价：块地址只剩 48 位
- 收益：接口不用改

48 位块地址 × 4096 字节 = 2^60 字节，这就是 EROFS "48-bit 地址"特性的由来。

**空洞怎么表示？**

阶段 1 见过那个离谱数字 `17592186040320`：

```
17592186040320 / 4096 = 0xFFFFFFFF
```

低 48 位全是 1，即 `EROFS_NULL_ADDR`。`data.c` 的判断就是识别它：

```c
if (addr ^ (EROFS_NULL_ADDR & addrmask))    /* 不等于 NULL → 正常地址 */
        addr |= ...;
else
        addr = EROFS_NULL_ADDR;              /* 等于 NULL → 这是空洞 */
```

**看到超大得离谱的物理地址，第一反应就该是"这是空洞"。**

---

## 3.6 `erofs_map_dev()`：确定是哪台设备

`erofs_map_blocks()` 给的是"文件系统内的地址"，
还需要确定"**在哪台设备上、设备内的哪个偏移**"——这就是 `erofs_map_dev()`（`data.c`）。

```c
int erofs_map_dev(struct super_block *sb, struct erofs_map_dev *map)
{
        ...
        erofs_fill_from_devinfo(map, sb, &EROFS_SB(sb)->dif0);  /* :216 默认主设备 */
        map->m_bdev = sb->s_bdev;                                /* :217 */
        if (map->m_deviceid) {
                down_read(&devs->rwsem);
                dif = idr_find(&devs->tree, map->m_deviceid - 1); /* :220 按 id 找 */
                if (!dif) {
                        up_read(&devs->rwsem);
                        return -ENODEV;
                }
                if (devs->flatdev) {
                        map->m_pa += erofs_pos(sb, dif->uniaddr); /* :226 扁平模式：只加偏移 */
                        up_read(&devs->rwsem);
                        return 0;
                }
                erofs_fill_from_devinfo(map, sb, dif);            /* :230 换成该设备 */
                up_read(&devs->rwsem);
        } else if (devs->extra_devices && !devs->flatdev) {
                /* 没有显式设备号时，遍历区间判断落在哪台设备（:232-247） */
        }
        return 0;
}
```

三条路径：

| 情况 | 处理 |
|---|---|
| `m_deviceid == 0` | 用主设备（`dif0`） |
| `m_deviceid != 0`，flatdev 模式 | 仍用主设备，但地址加上该设备的起始偏移（`:226`） |
| `m_deviceid != 0`，正常模式 | 换成对应设备的 `bdev`（`:230`） |

设备信息存在 **idr 树**里（`devs->tree`），按设备号索引。

回到 `erofs_iomap_begin()`，拿到设备后填 iomap（`data.c`）：

```c
        if (flags & IOMAP_DAX)
                iomap->dax_dev = mdev.m_dif->dax_dev;
        else
                iomap->bdev = mdev.m_bdev;
        iomap->addr = mdev.m_dif->fsoff + mdev.m_pa;     /* :338 */
```

注意 `:338` **加了 `fsoff`**——把"文件系统内地址"转换成"设备内地址"。

## 3.7 内联数据怎么读出来：`erofs_buf` 用上了

当 `map.m_flags` 有 `META` 时（即数据内联在元数据区），
`erofs_iomap_begin()` 走这段（`data.c`）：

```c
        if (map.m_flags & EROFS_MAP_META) {
                iomap->type = IOMAP_INLINE;
                /* read context should read the inlined data */
                if (ctx) {
                        struct erofs_buf buf = __EROFS_BUF_INITIALIZER;
                        void *ptr;

                        ptr = erofs_read_metabuf(&buf, sb, map.m_pa,
                                         erofs_inode_in_metabox(realinode));
                        if (IS_ERR(ptr))
                                return PTR_ERR(ptr);
                        iomap->inline_data = ptr;
                        ctx->page = buf.page;      /* ← 存起来，用完要 put */
                        ctx->base = buf.base;
                }
        }
```

**阶段 2 学的 `erofs_buf` 在这里派上了用场。**

注意最后两行：把 `buf.page` 和 `buf.base` 存进 `ctx`。
为什么？  
因为这个 buf 是**局部变量**，函数返回就没了，
但内联数据的指针要交给调用方使用，页必须保持被引用状态。

所以由调用方（或 `erofs_iomap_end`）负责在合适时机 `put`。

> 这正是阶段 2 讲的"释放义务全靠人工维系"的一个实例。  
> 读这段代码时，看到 `erofs_read_metabuf` 就应该去找对应的 `put`。

## 3.8 fileio 后端（简要）

除了块设备，EROFS 还支持"**镜像是个普通文件**"的挂载方式（fileio 后端）。

差别只在数据来源：

| | 块设备后端 | fileio 文件后端 |
|---|---|---|
| 数据从哪来 | `s_bdev`（块设备） | 后备文件（经 VFS 读） |
| `mapping` 指向 | `s_bdev->bd_mapping` | 后备文件的 `f_mapping` |
| Kconfig | 默认 | `EROFS_FS_BACKED_BY_FILE` |

**为什么要它？** 主要为了容器/云原生场景：
镜像只是一个文件（比如容器镜像里的一个 layer），不需要 loop 设备或块设备。

它替代了早期基于 fscache 的方案——**fscache 后端已在 7.2 内核被整体移除**。
细节留到阶段 6。

## 3.9 常见误解

**误解一：以为 `erofs_map_blocks` 返回的是"磁盘上的最终地址"**

不是。它返回的是**文件系统内**的物理地址（`m_pa`），
还要经过 `erofs_map_dev()` 加上 `fsoff` 并确定设备，
才是设备内的真实地址。这两个阶段不能混。

**误解二：以为 `IOMAP_HOLE` 会去读磁盘**

不会。空洞读出来是全 0，不产生任何 IO。
这也是稀疏文件省空间的原理（阶段 1 的 CHUNK_BASED 实测）。

**误解三：以为 FLAT_INLINE 的文件全部内联**

不。FLAT_INLINE 表示"**尾部**内联"，主体仍在独立数据块。
阶段 1 的 big.bin（100KB）就是活生生的例子。

**误解四：看到超大物理地址以为是 bug**

先算一下是不是 `0xFFFFFFFF << 12`（= 17592186040320）。
如果是，那是**空洞**的正常表示，不是 bug。

## 术语速查

| 术语 | 含义 | 出处 |
|---|---|---|
| `erofs_iomap_ops` | EROFS 交给 iomap 框架的操作集 | `data.c` |
| `IOMAP_HOLE` | 空洞，无对应磁盘数据 | `data.c` |
| `IOMAP_INLINE` | 数据内联在元数据区 | `data.c` |
| `IOMAP_MAPPED` | 数据映射到正常磁盘块 | `data.c` |
| `EROFS_MAP_META` | 标志：这段数据在元数据区 | `data.c` |
| `m_pa` | 文件系统内的物理地址（**字节**单位） | 3.4 |
| `m_la` | 文件内的逻辑地址 | 3.4 |
| `m_deviceid` | 设备号（编在地址高 16 位） | `data.c` |
| flatdev | 多设备扁平模式：都在主设备上，只加偏移 | `data.c` |

## 自测检查点

1. EROFS 的读入口有几个？为什么都走 iomap？
2. `erofs_iomap_begin()` 返回的 iomap 有哪三种 type？分别什么含义？
3. 阶段 1 的 big.bin 有两个 extent，代码里对应哪个分支判断？
4. `data.c` 的 `erofs_iblks(inode) - tailinline` 为什么要减 `tailinline`？
5. 用 big.bin 的真实数字（100000 字节，块 4096）算一遍 `pos`，验证是否等于 98304。
6. `EROFS_MAP_META` 标志有什么作用？没有它会怎样？
7. chunk-based 的 64 位地址里，高 16 位和低 48 位分别是什么？为什么这么设计？
8. 看到物理地址 17592186040320，你怎么判断它是空洞？
9. `erofs_map_blocks()` 和 `erofs_map_dev()` 的分工是什么？
10. `data.c` 为什么要把 `buf.page` 存进 `ctx`？

## 自测答案

<details>
<summary>点击展开答案</summary>

**1. 几个入口？为什么都走 iomap？**

四个：`erofs_read_folio`（`data.c`）、`erofs_readahead`（`data.c` 附近）、
`erofs_file_read_iter`（DIO）、`erofs_fiemap`/`erofs_bmap`（`data.c`/`:444`）。

都走 iomap 是因为：iomap 框架统一处理了预读策略、IO 提交、DAX、FIEMAP 等，
EROFS 只需实现"地址翻译"这一件事。这是 EROFS 代码量小的重要原因。

**2. iomap 的三种 type？**

| type | 含义 |
|---|---|
| `IOMAP_HOLE` | 空洞，读出来是 0，不产生 IO |
| `IOMAP_INLINE` | 数据内联在元数据区 |
| `IOMAP_MAPPED` | 数据映射到正常磁盘块 |

**3. big.bin 的两个 extent 对应哪个判断？**

对应 `data.c` 的 `if (map->m_la < pos)`：

- `m_la < pos`（前 98304 字节）→ 主体分支，数据在独立块
- `m_la >= pos`（最后 1696 字节）→ 尾部分支，数据内联在 inode 后

**4. 为什么要减 tailinline？**

因为如果有内联尾部，文件占用的最后一个块**不属于主体数据**。
减去 1 之后，`pos` 才是"主体数据的末尾"。

若 `tailinline = 0`（FLAT_PLAIN），减 0，`pos` 就是整个文件长度。

**5. 验算 pos？**

```
文件大小 = 100000 字节，块大小 = 4096
块数 = ceil(100000 / 4096) = ceil(24.41) = 25
tailinline = 1（FLAT_INLINE）
pos = (25 - 1) × 4096 = 24 × 4096 = 98304   ✓
```

与 `dump.erofs` 第一个 extent 的边界 98304 **完全一致**。

**6. `EROFS_MAP_META` 的作用？**

它标记"这段数据在元数据区，不在数据区"。

有它 → `erofs_iomap_begin` 走 `IOMAP_INLINE`（`data.c`），
用 `erofs_read_metabuf` 从元数据缓存读。

没有它 → 会走 `IOMAP_MAPPED`，把元数据区的地址当成数据块地址提交给 block layer，
读到完全错误的内容。

**7. chunk 的 64 位地址？**

- 高 16 位（bit 63~48）= **device_id**（设备号）
- 低 48 位（bit 47~0）= **设备内的物理块地址**

设计原因：映射函数的返回值只有"地址"一个字段，
多设备支持是后加的，为了不改接口签名，把设备号塞进高位。
代价是块地址只剩 48 位（这也是"48-bit 地址"特性的由来）。

**8. 怎么判断是空洞？**

```
17592186040320 / 4096 = 4294967295 = 0xFFFFFFFF
```

低 48 位全 1 = `EROFS_NULL_ADDR`（-1），即空洞。
内核在 `data.c` 专门判断这个。

**9. 两者的分工？**

- `erofs_map_blocks()`：**文件偏移 → 文件系统内的物理地址**（`m_pa`），
  并给出 `META`/`MAPPED` 等标志。还没确定设备。
- `erofs_map_dev()`：**按设备号找到设备**，把 `m_pa` 加上 `fsoff`
  转换成设备内的真实地址，并给出 `bdev`/`dax_dev`。

两者是"翻译"的两个阶段，不能混。

**10. 为什么存 buf.page 到 ctx？**

因为 `buf` 是**局部变量**，函数返回即失效；
但内联数据的指针（`iomap->inline_data`）要交给调用方继续使用，
对应的页必须保持引用状态不能被回收。

所以把 `buf.page`/`buf.base` 存进 `ctx`，
由调用方在用完后负责 `put`——
这正是阶段 2 讲的"释放义务全靠人工维系"的实例。

</details>

## 与后续阶段的关系

- **阶段 4**：压缩路径。同样要"翻译"，但**不能做算术**——必须查索引。
  本章的 `erofs_map_blocks` 对应压缩路径的 `z_erofs_map_blocks_iter`
- **阶段 6**：多设备详解（本章只讲了 `erofs_map_dev` 的基本逻辑）、
  fileio 后端详解、FSDAX

## 参考
  [linux-7.2](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)
