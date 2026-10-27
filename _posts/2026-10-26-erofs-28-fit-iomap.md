---
layout:     post
title:      EROFS graft iomap
subtitle:   EROFS 嫁接 iomap
date:       2026-10-26
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
---

# EROFS 对 iomap 机制的运用：源码级专题分析

> **源码基线**：`a804c5742bff`（v7.4-rc1 合并窗口后），源码树 `/home/linux/erofs/linux-stable`  

---

## 0. 摘要

EROFS 自 v5.15 起把全部**非压缩**文件的读路径建立在 iomap 框架之上，  
压缩文件则保留自研解压管线、只在 fiemap/llseek 这类「报告型」接口上借用 iomap。  
到了 7.4 窗口，EROFS 又利用 v6.19 引入的 `iomap_read_ops` 回调抽象，  
把**文件后端（file-backed / fileio）挂载**也接进了同一条 iomap 读路径。  
全树一共 6 处 `iomap_read_ops` 定义，可以清楚分成两类：

| 文件系统                             | `read_folio_range`           | 性质                                                                                                                          |
| ------------------------------------ | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| XFS（`xfs_aops.c`）                  | `iomap_bio_read_folio_range` | 仍走 bio；只在设备带 integrity checksum 时才启用这套 ops（`xfs_get_iomap_read_ops()`），否则直接用内置的 `iomap_bio_read_ops` |
| exfat / ntfs3 / ntfs                 | `iomap_bio_read_folio_range` | 仍走 bio，只自定义 `submit_read`（换 bio_set / 加 end_io）                                                                    |
| **FUSE**（`fuse/file.c`）            | `fuse_do_readfolio()`        | **非块设备 I/O**，走 FUSE 协议                                                                                                |
| **EROFS fileio**（`erofs/fileio.c`） | `vfs_iocb_iter_read()`       | **非块设备 I/O**，走**另一个文件的 `->read_iter`**                                                                            |

即：EROFS 不是唯一把 iomap 接到非块设备上的（FUSE 更早），但它是唯一一个把 I/O 交给**另一个文件的 `->read_iter`** 的用法。

一句话概括 EROFS 的 iomap 使用策略：**用 iomap 管「文件偏移 → 物理位置」的映射与页缓存交互，  
解压这种 iomap 模型覆盖不了的事，留给自己的 zdata 管线。**

---

## 1. 背景介绍

### 1.1 EROFS 的设计目标

EROFS（Enhanced Read-Only File System）是面向只读场景的 Linux 文件系统，  
设计目标可以归纳为四条：

1. **只读语义**：磁盘上没有任何可写结构。  
   没有写回、没有 truncate、没有日志、没有 delalloc。  
   `fs/erofs/data.c` 里 `erofs_read_folio()` 开头的注释把这一点用到了极致：

   > since we dont have write or truncate flows, so no inode locking needs to be held at the moment.

   读路径连 inode 锁都不用拿——这是后文所有简化的根源。

2. **压缩存储**：支持 LZ4 / LZMA / DEFLATE /ZSTD（枚举见 `fs/erofs/erofs_fs.h` 的 `Z_EROFS_COMPRESSION_LZ4/LZMA/DEFLATE/ZSTD`），  
   以固定输出窗口（pcluster）为单位组织压缩数据（`fs/erofs/zdata.c`、  
   `fs/erofs/zmap.c`）。

3. **空间效率**：tailpacking inline（文件尾部直接内联在 inode 块尾）、  
   fragment（多个文件的尾部共享一个 packed inode）、chunk-based 大文件索引、  
   blobdev 多设备拼接、以及 **v6.17** 引入的 metabox 元数据压缩（`681acbda3a6d`，  
   该 tag 已核实）。

4. **部署形态持续扩展**：块设备镜像 → fsdax 直接映射 → 文件后端挂载（fileio，  
   服务容器镜像按需加载场景，即 `EROFS_FS_BACKED_BY_FILE`）。

### 1.2 引入 iomap 的动机与意义

v5.15 之前，EROFS 非压缩路径用的是 `erofs_raw_access_aops`——  
`.readpage = erofs_raw_access_readpage`、  
`.readahead = erofs_raw_access_readahead`（内部 `readahead_page()` 逐页循环 + 自制 bio 组装）。  
`771c994ea51f` 一笔提交就把 `data.c` 从 290 处改动里删掉 239 行、  
只加回 51 行。  
转向 iomap 的动机在两份提交说明里写得很直白：

**动机一：DIO 消除双份页缓存**（`a08e67a02802`，v5.15）：

> Direct I/O is useful in certain scenarios for uncompressed files. For example,  
> double pagecache can be avoid by direct I/O  
> when loop device is used for uncompressed files containing upper layer compressed filesystem.

**动机二：tailpacking inline 已被 iomap 原生支持**（`771c994ea51f`，v5.15）：

> Since tail-packing inline has been supported by iomap now,  
> let's convert all EROFS uncompressed data I/O to iomap,  
> which is pretty straight-forward.

这里说的「已被支持」指的是 iomap 侧的 `69f4a26c1e0c`「iomap: support reading inline data from non-zero pos」（2021-08-03，  
v5.15，同样是高翔提交）——EROFS 的 tailpacking 内联数据位于块内**非零偏移**，  
老的 iomap inline 模型放不下，这个提交补上后，EROFS 全量切换就没有障碍了。

**iomap 给 EROFS 换来的东西**：

* 免费的 folio 化与子块（sub-folio）管理；  
* 统一的 `readahead` / `read_folio` / DIO / DAX / fiemap / seek 框架，  
  每加一个内核新能力（如后来的大 folio、readahead 扩展）都不再需要改 EROFS 自己；  
* 一个稳定的「文件偏移 → 设备物理位置」契约（`struct iomap`），后续 fileio、  
  多设备、DAX 都是在这张契约上换实现。

### 1.3 EROFS 的 iomap 演进时间线

| 时间    | 版本     | 提交           | 内容                                              |
| ------- | -------- | -------------- | ------------------------------------------------- |
| 2021-08 | v5.15    | `a08e67a02802` | iomap 支持非 tailpacking 文件的 DIO               |
| 2021-08 | v5.15    | `06252e9ce05b` | iomap 支持非 tailpacking 文件的 DAX               |
| 2021-08 | v5.15    | `771c994ea51f` | **全部非压缩路径切到 iomap**                      |
| 2021-08 | v5.15    | `eadcd6b5a1eb` | fiemap 走 iomap（同时引入压缩文件的 report ops）  |
| 2024-10 | v6.13    | `83a8836fa19a` | `SEEK_DATA` / `SEEK_HOLE` 走 iomap                |
| 2025-09 | v6.19    | `b2f35ac4146d` | （iomap 侧）新增 `iomap_read_ops` 回调抽象        |
| 2026-07 | v7.3     | `32055631cc5e` | EROFS 的 ops 转成 `->iomap_next()` 形态（纯重构） |
| 2026-10 | 7.4 窗口 | `1137aa577a35` | **fileio 挂载的非压缩 inode 走 iomap**（无 tag）  |

---

## 2. iomap 在 EROFS 中的整体架构

### 2.1 核心架构决策：两套 aops 的分野

EROFS 对 iomap 最重要的架构决策不是「怎么用」，而是「**哪里不用**」：

|              | 非压缩文件                                                                    | 压缩文件                                      |
| ------------ | ----------------------------------------------------------------------------- | --------------------------------------------- |
| aops         | `erofs_aops`（`data.c`）                                                      | `z_erofs_aops`（`zdata.c`）                   |
| `read_folio` | `erofs_read_folio` → `iomap_read_folio()`                                     | `z_erofs_read_folio`（自研解压管线）          |
| `readahead`  | `erofs_readahead` → `iomap_readahead()`                                       | `z_erofs_readahead`                           |
| DIO          | `iomap_dio_rw()`（仅块设备后端）                                              | 不支持                                        |
| DAX          | `dax_iomap_rw()` / `dax_iomap_fault()`，但**仅 `FLAT_PLAIN` / `CHUNK_BASED`** | 不支持                                        |
| fiemap       | `iomap_fiemap()` + `erofs_iomap_ops`                                          | `iomap_fiemap()` + `z_erofs_iomap_report_ops` |
| llseek       | `iomap_seek_hole/data` + `erofs_iomap_ops`                                    | 同左，换 report ops                           |
| bmap         | `iomap_bmap()`                                                                | （不支持）                                    |

分发点在 `erofs_get_aops()`（`fs/erofs/internal.h`）：  
datalayout 为压缩时返回 `z_erofs_aops`，若内核未编 `CONFIG_EROFS_FS_ZIP` 则返回 `-EOPNOTSUPP`；  
其余返回 `erofs_aops`。  


inode 共享（`erofs_ishare`，`ishare.c`）路径也走同一个分发点：  
`erofs_ishare_fill_inode()` 里先 `aops = erofs_get_aops(inode)`，  
再赋给共享 inode 的 `si->i_mapping->a_ops`（并同样 `mapping_set_large_folios()`）——  
所以 ishare 文件在「压缩 / 非压缩」上的分野与主路径完全一致。



一个容易忽略的限制：**DAX 的排除范围比「压缩」更大**。`erofs_fill_inode()`（`inode.c`）里的判定是：

```c
inode->i_flags &= ~S_DAX;
if (test_opt(&sbi->opt, DAX_ALWAYS) && S_ISREG(inode->i_mode) &&
    (vi->datalayout == EROFS_INODE_FLAT_PLAIN ||
     vi->datalayout == EROFS_INODE_CHUNK_BASED))
	inode->i_flags |= S_DAX;
```

即 **tailpacking inline 文件（`FLAT_INLINE`）同样拿不到 DAX**，  
这与 v5.15 那笔提交标题「dax support for **non-tailpacking** regular file」一致。

`zdata.c` 中 grep 不到任何 iomap 调用——  **压缩路径与 iomap 完全分离**。  原因在 §3.5 展开。

### 2.2 映射层契约：`erofs_iomap_ops`

```c
/* fs/erofs/data.c */
static DEFINE_IOMAP_ITER_NEXT_END(erofs_iomap_next,
				  erofs_iomap_begin, erofs_iomap_end);

static const struct iomap_ops erofs_iomap_ops = {
	.iomap_next = erofs_iomap_next,
};
```

三个角色：

* **`erofs_iomap_begin()`**：把 EROFS 的 `erofs_map_blocks()` 结果翻译成 `struct iomap`（type /addr /  
  bdev / inline_data / private），见 §3.2。  
* **`erofs_iomap_end()`**：释放 begin 阶段持有的 metabuf 引用，  
  见 §3.3。  
  只读文件系统的 `written` 语义退化为「透传 advance 的字节数」。  
* **`DEFINE_IOMAP_ITER_NEXT_END`**：v7.3 引入的包装宏，  
  把 begin/end 编进 `->iomap_next` 单回调，让编译器去虚拟化（`iomap_iter_next()` 是 `__always_inline`，  
  回调变成直接调用）。

压缩文件另有一套只读 report ops（`zmap.c`）：

```c
static DEFINE_IOMAP_ITER_NEXT(z_erofs_iomap_next_report,
			      z_erofs_iomap_begin_report);

const struct iomap_ops z_erofs_iomap_report_ops = {
	.iomap_next = z_erofs_iomap_next_report,
};
```

不带 end 回调——因为它只填 `offset/length/type/addr`，  
不碰 metabuf 的常驻引用（`z_erofs_map_blocks_iter` 返回后立即 `erofs_put_metabuf()`），见 §3.5。

### 2.3 读执行层契约：`iomap_read_ops` 的双实现

v6.19 的 `b2f35ac4146d` 把「怎么把一段 range 读进 folio」从 iomap 里抽象成回调，  
EROFS 在 7.4 窗口用它实现了双后端：

```c
/* fs/erofs/data.c，erofs_read_folio() / erofs_readahead() 内 */
struct iomap_read_folio_ctx read_ctx = {
	.ops = erofs_is_fileio_mode(sbi) ?
		&erofs_fileio_iomap_read_ops : &iomap_bio_read_ops,
	...
};
```

* **块设备后端**：直接用 iomap 内置的 `iomap_bio_read_ops`（`fs/iomap/bio.c`，  
  攒 bio、跨 folio/跨 extent 合并、`submit_bio`）。  
* **文件后端**：`erofs_fileio_iomap_read_ops`（`fs/erofs/fileio.c`），  
  把 bio 翻译成对后端文件的 `vfs_iocb_iter_read()`，见 §3.4。

映射逻辑（`erofs_iomap_begin`）与读执行（`read_ops`）因此正交：  同一份映射结果，两种 I/O 引擎。

### 2.4 `erofs_iomap_iter_ctx`：EROFS 塞进 `iter->private` 的私有数据

```c
/* fs/erofs/internal.h */
struct erofs_iomap_iter_ctx {
	struct page *page;
	void *base;
	struct inode *realinode;
};
```

* `page` + `base`：begin 阶段为 INLINE 映射读入的 metabuf 引用，  end 阶段据此释放（§3.3）。  
* `realinode`：inode 共享（`erofs_ishare`，`fs/erofs/ishare.c`）  
  场景下，操作 inode 可能是个「共享壳」，真正的磁盘 inode 由 `erofs_real_inode()` 从共享链上 `igrab()` 一个出来；  
  这个指针同时被 `erofs_iomap_begin()`（用它取 sb、做 map_blocks）  和 fileio 的 `read_folio_range`（用它取 sb）使用。

取回这个 ctx 的手法是一个值得注意的技巧——`erofs_iomap_begin/end` 的参数里只有 `struct iomap *`，  
靠 `container_of` 反推回迭代器：

```c
struct iomap_iter *iter = container_of(iomap, struct iomap_iter, iomap);
struct erofs_iomap_iter_ctx *ctx = iter->private;
```

合法性来自 `iomap` 是 `iomap_iter` 的内嵌成员。

### 2.5 与其他使用者的对比

iomap 的典型用户（XFS、GFS2、btrfs）都是**可写**文件系统，它们用的是 iomap 的重头部分：  
写路径 `iomap_write_ops`、delalloc 释放、ioend 写回合并、`page_mkwrite`。  


EROFS 恰好证明了 iomap 契约的另一半价值：**只读文件系统可以只实现「映射 + 读」两个回调就接入整个页缓存生态**。  


编译单元层面也呼应这一点：`fs/iomap/Makefile` 里只有 `trace.o iter.o buffered-io.o` 无条件编译，  
EROFS 用到的 bio/fiemap/seek/dio 都在 `CONFIG_BLOCK` 附加件里。

---

## 3. 核心流程分析

### 3.1 缓冲读路径全景

先纠正一个常见误会：**`read()` 路径实际走的是 `->readahead`，不是 `->read_folio`**。  
`filemap_read()` → `filemap_get_pages()` 缺页时调 `filemap_readahead()` → `page_cache_async_ra()`，  
MM 构造出 `readahead_control` 后调 `a_ops->readahead`（`mm/readahead.c` 的 `read_pages()`：  
有 `->readahead` 就用它，没有才退化成逐 folio 调 `->read_folio`）。  
EROFS 两个回调都实现了，所以读文件的入口是 `erofs_readahead()`；  
`erofs_read_folio()` 走的是 `read_cache_folio()` 这类单页同步读路径。  
两者结构完全对称，差别只在 `iomap_read_folio_ctx` 里填 `.cur_folio` 还是 `.rac`：

```
filemap_read()                                        [mm/filemap.c]
  └─ filemap_get_pages()
       └─ filemap_readahead() → page_cache_async_ra()
            └─ read_pages()                           [mm/readahead.c]
                 └─ aops->readahead = erofs_readahead()          [data.c]
                      ├─ erofs_real_inode()      /* ishare 场景换真 inode */
                      ├─ read_ctx = { .ops = fileio? fileio_ops : bio_ops,
                      │               .rac = rac }
                      └─ iomap_readahead(&erofs_iomap_ops, &read_ctx, &iter_ctx)
                           [fs/iomap/buffered-io.c]
                           └─ while (iomap_iter(&iter, ops) > 0)
                                ├─ erofs_iomap_next()          [宏展开]
                                │    └─ iomap_iter_next()
                                │         ├─ erofs_iomap_end(上一段)    /* 放 metabuf */
                                │         ├─ iomap_iter_continue()      /* 判定继续 */
                                │         └─ erofs_iomap_begin(下一段)  /* 产出映射 */
                                └─ iomap_readahead_iter()      /* 轮转 folio */
                                     └─ iomap_read_folio_iter()  /* 按 type 分派，见下 */
```

单页同步读（`read_cache_folio()` 之类）走的是另一个入口，结构与上面完全对称，  
差别只在 ctx 里填 `.cur_folio` 而非 `.rac`、  
以及外层用 `iomap_read_folio()` 而不是 `iomap_readahead()`（后者内部少了 folio 轮转那一层）：

```
erofs_read_folio()                                    [data.c]
  └─ iomap_read_folio(&erofs_iomap_ops, &read_ctx, &iter_ctx)
       └─ while (iomap_iter(&iter, ops) > 0)
            ├─ erofs_iomap_next()      /* 同上 */
            └─ iomap_read_folio_iter()
```

`iomap_read_folio_iter()`（`buffered-io.c`）对 EROFS 产出的映射只会走三条路：

| iomap type     | EROFS 何时产出                            | 处理                                                    |
| -------------- | ----------------------------------------- | ------------------------------------------------------- |
| `IOMAP_INLINE` | `EROFS_MAP_META`（tailpacking / metabox） | `iomap_read_inline_data()`：`folio_fill_tail` 拷贝+补零 |
| `IOMAP_HOLE`   | chunk 空洞 / 超 i_size                    | `folio_zero_range` 补零                                 |
| `IOMAP_MAPPED` | 普通数据块                                | `ctx->ops->read_folio_range()` 发 I/O                   |

读完成的收尾分两条：

* bio 路径：`iomap_read_end_io()` → `iomap_finish_folio_read()`（置 uptodate 位图，  
  `read_bytes_pending` 归零后 `folio_end_read`）；  
* fileio 路径：`erofs_fileio_ki_complete()` 里对每个 folio 调 `iomap_finish_folio_read()`——  
  同一个收尾函数，满足 iomap_read_ops 契约（「`read_folio_range` 成功就必须调 `iomap_finish_folio_read`，无论成败」）。

### 3.2 地址映射：`erofs_iomap_begin` 的翻译逻辑

`erofs_iomap_begin()`（`data.c`）本身很薄，核心在 `erofs_map_blocks()`。  
EROFS 非压缩 inode 有三种磁盘布局（`datalayout`），翻译结果如下：

| EROFS datalayout          | 特征                                                                                    | iomap type                                          |
| ------------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `EROFS_INODE_FLAT_PLAIN`  | 整文件连续存放在 `startblk`                                                             | `IOMAP_MAPPED`                                      |
| `EROFS_INODE_FLAT_INLINE` | 前部连续 + **尾部内联在 inode 块尾**                                                    | 前部 `MAPPED`，尾部 `INLINE`                        |
| `EROFS_INODE_CHUNK_BASED` | chunk 索引数组（索引项 4 或 8 字节，取决于 `chunkformat`），可含 `EROFS_NULL_ADDR` 空洞 | 逐项翻译：连续 chunk 合并为 `MAPPED`，空洞为 `HOLE` |

`erofs_map_blocks()` 的关键分支：

```c
} else if (tailinline || vi->startblk != EROFS_NULL_ADDR) {
	pos = erofs_pos(sb, erofs_iblks(inode) - tailinline);
	if (map->m_la < pos) {
		/* 前部：连续块 */
		map->m_pa = erofs_pos(sb, vi->startblk) + map->m_la;
		map->m_flags = EROFS_MAP_MAPPED;
	} else {
		/* 尾部：inline 在 inode 块尾（或 metabox） */
		map->m_pa = erofs_iloc(inode) + vi->inode_isize +
			vi->xattr_isize + erofs_blkoff(sb, map->m_la);
		map->m_flags |= EROFS_MAP_META;
		/* inline 数据跨块 = 镜像损坏 */
		if (erofs_blkoff(sb, map->m_pa) + map->m_llen >
		    sb->s_blocksize)
			return -EFSCORRUPTED;
	}
}
```

回到 `erofs_iomap_begin()`，三级翻译：

```c
if (!(map.m_flags & EROFS_MAP_MAPPED)) {
	iomap->type = IOMAP_HOLE;               /* 空洞：m_flags==0 */
	return 0;
}
if (!(map.m_flags & EROFS_MAP_META) || !erofs_inode_in_metabox(realinode)) {
	erofs_map_dev(sb, &mdev);             /* 解析多设备 */
	iomap->private = mdev.m_dif;          /* ★ 携带后端设备信息 */
	iomap->bdev = mdev.m_bdev;            /* （IOMAP_DAX 时换 dax_dev） */
	iomap->addr = mdev.m_dif->fsoff + mdev.m_pa;
}
if (map.m_flags & EROFS_MAP_META) {
	iomap->type = IOMAP_INLINE;           /* 内联：见 §3.3 */
	...
} else {
	iomap->type = IOMAP_MAPPED;
}
```

两个细节：

1. **`erofs_map_dev()` 与多设备**：blobdev 场景下 `map.m_deviceid` 非 0，  
   `erofs_map_dev()` 查设备表（`devs->tree`，支持 flatdev 拼接模式），  
   最终把「镜像内物理地址」换算成「某设备上的偏移」。**  
   `iomap->private` 被复用来携带 `struct erofs_device_info *`**——  
   这正是 `iomap.h` 给文件系统留的私有字段，fileio 的 `read_folio_range` 靠它找到后端文件（`dif->file`）。

   注意 `iomap->addr` 是 `mdev.m_dif->fsoff + mdev.m_pa`：  
   **`fsoff` 是「该设备在镜像地址空间里的起始偏移」**（可由 `fsoffset=` 挂载选项指定，  见 `sbi->dif0.fsoff`）。  
   它是「镜像内地址 → 设备内地址」换算的一部分，iomap 只看到一个扁平的 `addr`，换算责任全在 EROFS 侧。

2. **chunk 合并**（`erofs_map_chunks()`）：从请求的 chunk 号开始连续向后扫描，  
   物理地址相邻的 chunk 合并成一个映射段（`do { ... } while (addr == last && ...)`），  
   减少 iomap 迭代次数。  
   `EROFS_NULL_ADDR` 项终止合并并产生 HOLE。

### 3.3 inline（tailpacking / metabox）与 metabuf 生命周期

INLINE 是 EROFS 对 iomap 用得最深的一个 type，也是 `erofs_iomap_ops` 必须带 end 回调的原因。

begin 阶段（`erofs_iomap_begin()` 的 `EROFS_MAP_META` 分支）：

```c
iomap->type = IOMAP_INLINE;
if (ctx) {
	ptr = erofs_read_metabuf(&buf, sb, map.m_pa,
				 erofs_inode_in_metabox(realinode));
	iomap->inline_data = ptr;	/* 指向 metabuf 页内偏移 */
	ctx->page = buf.page;
	ctx->base = buf.base;
}
```

`erofs_read_metabuf()` 返回的指针指向一个被**引用计数持有**的 metabuf 页面。  
谁来释放？  
答案是 `iomap_iter_next()` 的「结束上一段 → 产出下一段」节奏：消费完这段 INLINE 映射之后、  
begin 下一段之前，`erofs_iomap_end()` 被调用：

```c
static int erofs_iomap_end(...)
{
	if (ctx && ctx->base) {
		struct erofs_buf buf = { .page = ctx->page, .base = ctx->base };
		DBG_BUGON(iomap->type != IOMAP_INLINE);
		erofs_put_metabuf(&buf);	/* 归还 metabuf 引用 */
		ctx->base = NULL;
	}
	return written;
}
```

iomap 侧的消费动作是 `iomap_read_inline_data()`（`buffered-io.c`）：  
`folio_fill_tail()` 把 `inline_data` 拷进 folio 并把剩余部分补零。  
iomap 约定「**每个文件末尾只允许有一个 IOMAP_INLINE extent**」，  
与 EROFS「tailpacking 内联只在文件尾部」的设计恰好同构。

> **补充：`srcmap` 的缺席。**  
> `erofs_iomap_begin()` 从头到尾没有碰过 `srcmap` 参数。  
> srcmap 是给 reflink/COW 文件系统表示「写入源」用的，只读的 EROFS 不需要，  
> 于是 srcmap 恒为全 0（`type == IOMAP_HOLE == 0`），`iomap_iter_srcmap()` 永远返回 dstmap、  
> `iomap_length_trim()` 只按 `iomap` 边界裁剪。  
> 这是只读文件系统接入 iomap 的默认姿态。

### 3.4 fileio 路径：把 bio 翻译成对后端文件的 read_iter

fileio 挂载（镜像是文件而非块设备）下，`erofs_fileio_iomap_read_ops`（`fileio.c`）  
替换默认的 bio 引擎：

```c
const struct iomap_read_ops erofs_fileio_iomap_read_ops = {
	.read_folio_range	= erofs_fileio_iomap_read_folio_range,
	.submit_read		= erofs_fileio_iomap_submit_read,
};
```

`erofs_fileio_iomap_read_folio_range()` 的语义与 iomap 内置的 `iomap_bio_read_folio_range()`（`fs/iomap/bio.c`）  
**逐条对齐**：不连续或加不进去就提交旧请求、另起新请求；  
`ctx->read_ctx` 攒着当前请求。  
区别在于攒的对象不是 `struct bio`，而是：

```c
struct erofs_fileio_rq {
	struct bio_vec bvecs[16];	/* 内嵌 bvec 数组，单请求上限 16 段 */
	struct bio bio;
	struct kiocb iocb;
	struct super_block *sb;
	refcount_t ref;
};
```

提交时（`erofs_fileio_rq_submit()`）：

```c
rq->iocb.ki_pos = rq->bio.bi_iter.bi_sector << SECTOR_SHIFT;
rq->iocb.ki_complete = erofs_fileio_ki_complete;
if (test_opt(&EROFS_SB(rq->sb)->opt, DIRECT_IO) &&
    rq->iocb.ki_filp->f_mode & FMODE_CAN_ODIRECT)
	rq->iocb.ki_flags = IOCB_DIRECT;
iov_iter_bvec(&iter, ITER_DEST, rq->bvecs, ...);
scoped_with_creds(rq->iocb.ki_filp->f_cred)
	ret = vfs_iocb_iter_read(rq->iocb.ki_filp, &rq->iocb, &iter);
```

即：**对后端文件发起 `->read_iter`**（按需可挂 `IOCB_DIRECT`），  
完成回调里对每个 folio 调 `iomap_finish_folio_read()` 收尾。  
`-EIOCBQUEUED` 走异步回调，否则同步完成；  
`ref` 双持（提交方与完成方各减一次）保证 `rq` 生命周期安全。

**两层「DIO」严格区分**：

* 上面这个 `IOCB_DIRECT` 是「**读后端文件**时用 O_DIRECT」，  
  由 fileio 挂载的 `directio` 选项控制（`super.c` 只在 fileio 模式下才显示该选项）；  
* EROFS 自己文件上的 `O_DIRECT` 是另一回事，只在块设备后端可用（见 §3.6 的 `s_bdev` 守卫）。

**别忘了 fileio 模式下的元数据读不走 iomap**：`erofs_read_meta_folio()`（`fileio.c`）  
自己组装 `erofs_fileio_rq`（挂 `erofs_fileio_meta_endio` 作为 `bi_end_io`）  
并发起 `vfs_iocb_iter_read()`，用的是 `folio_end_read()` 而非 `iomap_finish_folio_read()`。  
也就是说：**iomap 只覆盖 fileio mount 上的「非压缩文件数据读」**，  
元数据（superblock / inode / xattr / 目录）  
的读取仍然是 `erofs_buf` / `erofs_read_metabuf` 那套自研路径（块设备后端则走 `erofs_bread()` 系列）。

### 3.5 压缩数据与 iomap 的协同方式

**结论先行：压缩文件的读路径不走 iomap。**  
`fs/erofs/zdata.c` 中没有任何 iomap 调用，`z_erofs_aops` 的 `read_folio` / `readahead` 是自研解压管线：

以 `z_erofs_read_folio()`（`zdata.c`）为例，真实调用序列是：

```c
static int z_erofs_read_folio(struct file *file, struct folio *folio)
{
	realinode = erofs_real_inode(sharedinode, &need_iput);
	Z_EROFS_DEFINE_FRONTEND(f, realinode, sharedinode, folio_pos(folio));

	/* backmost=true：先把「请求范围末尾」映射出来（READMORE 标志），
	 * 用于确定最末那个 pcluster；readahead 场景还会
	 * 用 readahead_expand() 把尾部一次性扩展到位 */
	z_erofs_pcluster_readmore(&f, NULL, true);
	err = z_erofs_scan_folio(&f, folio, false);  /* ★ 扫描本 folio 需要哪些 pcluster */
	/* backmost=false：把相邻 pcluster 收进预读集合 */
	z_erofs_pcluster_readmore(&f, NULL, false);
	z_erofs_pcluster_end(&f);

	err = z_erofs_runqueue(&f, 0) ?: err;        /* ★ 提交 bio + 解压 + 合成 */
	erofs_put_metabuf(&f.map.buf);
	erofs_release_pages(&f.pagepool);
	...
}
```

即：`z_erofs_scan_folio()` 负责「逻辑 → pcluster」的扫描与记账（内部调 `z_erofs_map_blocks_iter()`），  
`z_erofs_runqueue()` 负责把攒下的 pcluster 组 bio 下发、  并在解压工作队列里解压合成目标页。  


其中「复用上次解压结果」的机制叫 **managed cache**，不是 iomap 的东西：  
`sbi->managed_cache`（`erofs_sb_info` 里的「pseudo inode to cache physical data」）  
配合 `sbi->managed_pslots` xarray 缓存最近解压出来的 pcluster 页，  
`erofs_folio_is_managed()` 用于判定一个 folio 是否来自该缓存，  命中即可免去重复解压。  


这个伪 inode 的 aops 是 `z_erofs_cache_aops`——  
注意它**只挂了自研的 `release_folio` / `invalidate_folio` 两个回调**，  
与 `erofs_aops` 在这两个位置直接挂 iomap 内置实现形成对照：  

缓存页的回收语义是 EROFS 自己定义的，iomap 无从插手。



不走 iomap 的根本原因是**模型不匹配**：iomap 的读模型是「一段文件偏移 ↔ 一段设备扇区，  bio 直接填进目标 folio」；  
而 EROFS 压缩数据的解压单位是 pcluster（固定**输出**窗口），一个目标 folio 可能由多个 pcluster 拼成，  
一个 pcluster 也可能同时服务多个 folio，中间还有 pcluster 预读/合并、  解压工作队列、在线页合成、managed cache 复用等机制。  
这种多对多关系塞不进「bio_for_each_folio」式的直接填充模型。

**压缩与 iomap 的交集在「报告型」接口**——fiemap / llseek 只需要回答「逻辑偏移落在哪段物理区间」，  不需要真的读数据。  
这时 iomap 的映射迭代器恰好合用：

```c
/* fs/erofs/zmap.c，z_erofs_iomap_begin_report() */
ret = z_erofs_map_blocks_iter(inode, &map, EROFS_GET_BLOCKS_FIEMAP);
erofs_put_metabuf(&map.buf);

if (map.m_flags & EROFS_MAP_FRAGMENT) {
	iomap->type = IOMAP_MAPPED;
	iomap->addr = IOMAP_NULL_ADDR;      /* ★ fragment 的地址无效化 */
} else if (map.m_flags & EROFS_MAP_MAPPED) {
	iomap->type = IOMAP_MAPPED;
	iomap->addr = map.m_pa;
} else {
	iomap->type = IOMAP_HOLE;
	...
}
```

两个定制点：

1. **FRAGMENT 映射成 `MAPPED + IOMAP_NULL_ADDR`**：  
   fragment（packed inode 里的文件尾巴）有逻辑上的物理位置，但不能直接当扇区地址用（它在 packed inode 里，  
   需要 `z_erofs_read_fragment()` 特殊处理）。  
   fiemap 只关心「这段不是空洞」，所以报 MAPPED 但地址置无效。  
2. **post-EOF 防死循环修正**：hole 落在 i_size 之后时，把 length 修正为 `length + offset - map.m_la`，  
   否则 iomap 迭代器会在 EOF 之后原地踏步（对应 `iomap_iter_continue()` 的 `advanced==0 && !STALE → 终止` 保护之前的空转）。

这套 report ops 只填映射、不持有 metabuf 常驻引用（`z_erofs_map_blocks_iter` 返回后立即 `erofs_put_metabuf`），  
所以可以用 `DEFINE_IOMAP_ITER_NEXT`（无 end 回调）——  
与 `erofs_iomap_ops` 必须用 `DEFINE_IOMAP_ITER_NEXT_END` 形成对照，  
原因见 §3.3。

### 3.6 DIO 与 DAX

`erofs_file_read_iter()`（`data.c`）的三个分支：

```c
if (IS_ENABLED(CONFIG_FS_DAX) && IS_DAX(inode))
	return dax_iomap_rw(iocb, to, &erofs_iomap_ops);

if ((iocb->ki_flags & IOCB_DIRECT) && inode->i_sb->s_bdev) {
	return iomap_dio_rw(iocb, to, &erofs_iomap_ops,
			    NULL, 0, &iter_ctx, 0);
}
return filemap_read(iocb, to, 0);
```

* **DAX**：直接交给 `dax_iomap_rw()` / 缺页走 `dax_iomap_fault()`。  
  `erofs_iomap_begin()` 在 `IOMAP_DAX` 标志下会填 `dax_dev` 并把 `addr` 加上 `dax_part_off`。  
  注意 DAX 只对 `FLAT_PLAIN` / `CHUNK_BASED` 生效（§2.1），  
  所以这里 `IS_DAX(inode)` 为真时，映射必然是纯数据块映射，不会遇到 INLINE。  
* **DIO**：`iomap_dio_rw()`，**dops 传 NULL**（只读场景没有 unwritten 转换这类完成时工作，  
  不需要 `end_io` 回调）。  
  注意 `inode->i_sb->s_bdev` 守卫：fileio 模式下 `s_bdev == NULL`（`erofs_fill_super()` 的 fileio 分支从不触碰 `s_bdev`），  
  O_DIRECT 直接退回 `filemap_read()`。  
  另外 DIO 分支**没有 datalayout 限制**——  
  v5.15 首笔 DIO 提交（`a08e67a02802`）只覆盖 non-tailpacking，  
  提交说明里写明「tail-packing inline files are handled in the follow-up patch」，  
  同一窗口的 `771c994ea51f`（convert all uncompressed cases to iomap）  
  把这部分带上了，所以现在 tailpacking 文件也能走 DIO（经 `iomap_dio_inline_iter`）。  
* `erofs_aops.direct_IO = noop_direct_IO`：DIO 不走老式 `->direct_IO` aop，  
  而是在 `->read_iter` 里显式分流——这是 iomap DIO 时代的标准做法。

只读场景下 `iomap_dio_rw` 只会走 READ 分支：  
EROFS 产出的映射只有 MAPPED / HOLE / INLINE 三种（只读文件系统没有 DELALLOC / UNWRITTEN），  
分别对应 `iomap_dio_bio_iter()` / `iomap_dio_hole_iter()`（读零）  
/ `iomap_dio_inline_iter()`（`copy_to_iter` 直接拷贝内联数据）。  
`iomap_dio_iter()` 里那个「Direct I/O collision with buffered writes」的 DELALLOC 告警对 EROFS 永远不会触发。

### 3.7 llseek / fiemap / bmap

```c
loff_t erofs_file_llseek(struct file *file, loff_t offset, int whence)
{
	const struct iomap_ops *ops = &erofs_iomap_ops;

	if (erofs_inode_is_data_compressed(EROFS_I(inode)->datalayout)) {
		if (!IS_ENABLED(CONFIG_EROFS_FS_ZIP))
			return generic_file_llseek(file, offset, whence);
		ops = &z_erofs_iomap_report_ops;
	}
	if (whence == SEEK_HOLE)
		offset = iomap_seek_hole(inode, offset, ops);
	else if (whence == SEEK_DATA)
		offset = iomap_seek_data(inode, offset, ops);
	...
}
```

`erofs_fiemap()` 同样的双 ops 结构；  
`erofs_bmap()` 直接是 `iomap_bmap()` 的薄封装。  
这三个接口都是 `IOMAP_REPORT` 型——只读迭代、不进页缓存、不发 I/O，  
是压缩文件唯一接入 iomap 的地方。

---

## 4. EROFS 实现与 iomap 源码的逐项对应

下面按 **iomap 源码的文件 / 符号**逐条列出 EROFS 的对接情况，未用到的直接标注「不涉及」。  
对照基准同样是 `a804c5742bff`。

### 4.1 `include/linux/iomap.h` —— 契约定义

| 符号                                                                           | EROFS 侧的对接                                                           | 说明                                                                                                                 |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `struct iomap`（`IOMAP_HOLE/DELALLOC/MAPPED/UNWRITTEN/INLINE`）                | 只产出 MAPPED / HOLE / INLINE 三种                                       | 只读 ⇒ 不会有 DELALLOC / UNWRITTEN                                                                                   |
| `iomap->private`                                                               | 装 `struct erofs_device_info *`                                          | 多设备 / blobdev 的后端身份，fileio 靠它取 `dif->file`                                                               |
| `iomap->inline_data`                                                           | 指向 metabuf 页内偏移                                                    | tailpacking / metabox 内联数据                                                                                       |
| `iomap->bdev` / `dax_dev`                                                      | 由 `erofs_map_dev()` 填；`IOMAP_DAX` 时换 `dax_dev`                      | 见 §3.2                                                                                                              |
| `struct iomap_ops` + `->iomap_next`                                            | `erofs_iomap_ops`、`z_erofs_iomap_report_ops`                            | v7.3 起用 `->iomap_next` 单回调形态                                                                                  |
| `DEFINE_IOMAP_ITER_NEXT_END` / `DEFINE_IOMAP_ITER_NEXT`                        | 生成 `erofs_iomap_next`（带 end）/ `z_erofs_iomap_next_report`（无 end） | 是否带 end 取决于 begin 是否持有需归还的资源                                                                         |
| `iomap_iter_next()`（`__always_inline`）                                       | 被上面两个宏包住，EROFS 不直接调用                                       | 内联后 begin/end 变成直接调用（去虚拟化）                                                                            |
| `struct iomap_read_ops`                                                        | 二选一：内置 `iomap_bio_read_ops` / 自研 `erofs_fileio_iomap_read_ops`   | **7.4 窗口核心改动**（`1137aa577a35`）；全树 6 处定义中只有 EROFS 把 I/O 交给另一个文件的 `->read_iter`（对比见 §0） |
| `struct iomap_read_folio_ctx`                                                  | 由 `erofs_read_folio` / `erofs_readahead` 构造，`.ops` 按后端二选一      | `.cur_folio` 或 `.rac`                                                                                               |
| `struct iomap_iter` 的 `private` 字段                                          | 装 `struct erofs_iomap_iter_ctx`（`page`/`base`/`realinode`）            | 靠 `container_of(iomap, struct iomap_iter, iomap)` 反推                                                              |
| `IOMAP_F_*` 标志                                                               | EROFS 侧一律填 0                                                         | `IOMAP_DAX` 等由上层传进来                                                                                           |
| `iomap_read_folio()` / `iomap_readahead()` 的便利包装 `iomap_bio_read_folio()` | 未使用（EROFS 自己构造 ctx）                                             |                                                                                                                      |
| `iomap_dio_read_simple()`                                                      | 未使用                                                                   | EROFS 走通用 `iomap_dio_rw`                                                                                          |

### 4.2 `fs/iomap/iter.c` —— 迭代器核心

| 符号                                                              | EROFS 侧的对接                               | 说明                                                          |
| ----------------------------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------- |
| `iomap_iter()`                                                    | 所有 EROFS iomap 入口的循环驱动              | EROFS 无定制                                                  |
| `iomap_iter_next()`                                               | 由 `DEFINE_IOMAP_ITER_NEXT*` 包住调用        | 内部完成「end 上一段 → 产出下一段」                           |
| `iomap_iter_continue()`                                           | 终止判定（`advanced==0 && !STALE`）          | EROFS 不改写                                                  |
| `iomap_iter_advance()` / `iomap_length()` / `iomap_iter_srcmap()` | 由 iomap 内部循环体调用                      | EROFS 从不填 `srcmap`，故 `iomap_iter_srcmap()` 恒返回 dstmap |
| `iomap_iter_done()`                                               | 记 `iter_start_pos` + 打 `iomap_iter_dstmap` | 无定制                                                        |

### 4.3 `fs/iomap/buffered-io.c` —— 缓冲读 / 写

| 符号                                                                         | EROFS 侧的对接                                    | 说明                                                                                                                          |
| ---------------------------------------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `iomap_read_folio()` / `iomap_readahead()`                                   | `erofs_read_folio` / `erofs_readahead` 薄封装     | 额外处理 ishare 的 `realinode` 换取与 `iput`                                                                                  |
| `iomap_readahead_iter()` / `iomap_read_folio_iter()`                         | 三路分派（INLINE / HOLE / MAPPED）全部会命中      | 见 §3.1                                                                                                                       |
| `iomap_read_inline_data()`                                                   | 直接复用                                          | 内部 `folio_fill_tail` 拷贝 + 补零                                                                                            |
| `iomap_finish_folio_read()`                                                  | fileio 的 `erofs_fileio_ki_complete()` 遵守该契约 | 「`read_folio_range` 成功就必须调，无论成败」                                                                                 |
| `struct iomap_folio_state` / `ifs_alloc()`                                   | 大 folio 下**会**启用                             | EROFS 无条件 `mapping_set_large_folios()`，块大小 4K < folio 大小 ⇒ `i_blocks_per_folio() > 1`；order-0 folio 才走无 ifs 分支 |
| `iomap_read_init()` / `iomap_read_end()`                                     | 无定制                                            | `read_bytes_pending` 的「先加满后减」                                                                                         |
| `iomap_release_folio()` / `iomap_invalidate_folio()`                         | 直接挂进 `erofs_aops`                             |                                                                                                                               |
| `iomap_file_buffered_write()` / `iomap_write_begin()` / `iomap_write_iter()` | **不涉及**                                        | 只读                                                                                                                          |
| `iomap_write_delalloc_release()`                                             | **不涉及**                                        | 只读 ⇒ 无 delalloc                                                                                                            |
| `iomap_zero_range()` / `iomap_truncate_page()`                               | **不涉及**                                        | 只读 ⇒ 无 truncate / fallocate                                                                                                |
| `iomap_page_mkwrite()`                                                       | **不涉及**                                        | 只读 ⇒ 无 mmap 写                                                                                                             |
| `iomap_folio_state` 的 `write_bytes_pending`                                 | **不涉及**                                        | 无写回                                                                                                                        |

### 4.4 `fs/iomap/bio.c` —— 读 bio 引擎

| 符号                                                      | EROFS 侧的对接                                              | 说明                                                                                |
| --------------------------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `iomap_bio_read_ops`                                      | 块设备后端直接复用                                          |                                                                                     |
| `iomap_bio_read_folio_range()` / `iomap_read_alloc_bio()` | fileio 侧自研等价物 `erofs_fileio_iomap_read_folio_range()` | 语义逐条对齐（不连续 / 装不下就提交旧的、另起新的），攒的对象换成 `erofs_fileio_rq` |
| `iomap_read_end_io()`                                     | bio 后端读完成 → `iomap_finish_folio_read()`                | 含 `bio_complete_in_task` 重投                                                      |
| `iomap_bio_submit_read_endio()`                           | 未使用                                                      | 自定义 end_io 钩子，XFS 用它挂 PI 验证                                              |

### 4.5 `fs/iomap/ioend.c` —— 写回 ioend

| 符号                                                                                                   | EROFS 侧的对接 | 说明                               |
| ------------------------------------------------------------------------------------------------------ | -------------- | ---------------------------------- |
| `iomap_add_to_ioend()` / `iomap_finish_ioends()` / `ioend_writeback_end_bio()` / `iomap_split_ioend()` | **不涉及**     | 只读 ⇒ 无写回，整个 ioend 层用不到 |

### 4.6 `fs/iomap/direct-io.c` —— 直接 I/O

| 符号                                  | EROFS 侧的对接                                   | 说明                                                                                                    |
| ------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| `iomap_dio_rw()` / `__iomap_dio_rw()` | `erofs_file_read_iter` 的 `IOCB_DIRECT` 分支调用 | dops 传 NULL；`s_bdev` 守卫使 fileio 模式退回 `filemap_read`                                            |
| `iomap_dio_iter()`                    | 只走 MAPPED / HOLE / INLINE 三支                 | DELALLOC 那一支（`pr_warn_ratelimited("Direct I/O collision with buffered writes!")`）对 EROFS 永不触发 |
| `__iomap_dio_read_simple()`           | 未使用                                           | 走通用 `iomap_dio_rw`                                                                                   |

### 4.7 `fs/iomap/fiemap.c` / `seek.c` / `swapfile.c` / `trace.h`

| 符号                                                                    | EROFS 侧的对接                    | 说明                                                                       |
| ----------------------------------------------------------------------- | --------------------------------- | -------------------------------------------------------------------------- |
| `iomap_fiemap()`（`fiemap.c`）                                          | `erofs_fiemap()` 双 ops 分流      | 压缩 inode 换 `z_erofs_iomap_report_ops`                                   |
| `iomap_bmap()`（`fiemap.c`）                                            | `erofs_bmap()` 薄封装             | legacy `->bmap`，0 表错误                                                  |
| `iomap_seek_hole()` / `iomap_seek_data()`（`seek.c`）                   | `erofs_file_llseek()` 双 ops 分流 | 同上                                                                       |
| `iomap_swapfile_activate()`（`swapfile.c`）                             | **不涉及**                        | 只读 ⇒ 不能做 swap                                                         |
| `trace.h` 的 `iomap_readpage` / `iomap_readahead` / `iomap_iter_dstmap` | 可用于 EROFS 读路径排查           | 与 EROFS 自己的 `trace_erofs_read_folio` / `trace_erofs_map_blocks_*` 互补 |

> **一句话总结这张对照表**：EROFS 用到的 iomap 代码集中在 `include/linux/iomap.h`（契约）、  
> `iter.c`（迭代）、`buffered-io.c` 的读半边、`bio.c`（块设备后端引擎）、  
> `direct-io.c` 的 READ 分支、以及 `fiemap.c` / `seek.c` 两个报告型接口；  
> `buffered-io.c` 的写半边、`ioend.c` 整层、`swapfile.c` 与 `iomap_dio_read_simple` 都因为「只读」而天然用不到。

---

## 5. 设计亮点与总结

### 5.1 设计亮点

1. **只读语义下的最小契约利用**。  
   EROFS 只实现了「映射 + 读」两组回调，就接入了 iomap 的 folio 管理、  
   readahead、DIO、DAX、fiemap、seek 全套设施；  
   写路径、ioend、delalloc、page_mkwrite 一概不碰。  
   这证明 iomap 的契约边界划得足够干净——只读文件系统接入的边际成本极低。

2. **begin/end 配对解决 metabuf 生命周期**。  
   内联数据的指针指向引用计数持有的 metabuf 页面，EROFS 用 `->iomap_begin` 取引用、  
   `->iomap_end` 放引用，恰好嵌进 `iomap_iter_next()`「结束上一段→产出下一段」的节奏里，  
   不需要任何额外的回调或状态机。  
   「要不要带 end」这个决策完全由「begin 是否持有需要归还的资源」决定，两套 ops（数据 ops 带 end、  
   z report ops 不带）是最直观的示范。

3. **`iomap->private` 的一字段多用**。  
   blobdev 多设备场景把 `struct erofs_device_info *` 塞进 `iomap->private`，  
   让 fileio 的读回调能找到后端文件——没有为 EROFS 改 iomap 一行通用代码。

4. **fileio 是 `iomap_read_ops` 抽象的第一个完整落地案例**。  
   v6.19 引入的回调抽象（`b2f35ac4146d`）在 7.4 窗口被 EROFS 用来把「读 bio」换成「读后端文件的 read_iter」，  
   同一份映射逻辑（`erofs_iomap_begin`）驱动两种 I/O 引擎，映射与执行的正交性得到了实战验证。

5. **持续吃到 iomap 框架演进的红利**。  
   v7.3 的 `->iomap_next` 转换（`32055631cc5e`）是纯重构，  
   EROFS 侧一共只动了两个文件、8 增 3 删（`data.c` +4/-2、`zmap.c` +4/-1，  
   全是 ops 定义相关），就获得了去虚拟化收益（`iomap_iter_next` 内联后 begin/end 变成直接调用）。  
   另一处红利是：**sub-folio 读的支持来自 iomap，不是自研**。  
   EROFS 在 `erofs_fill_inode()` 里无条件调用 `mapping_set_large_folios()`，  
   页缓存可以分配大 folio（如 64K），而 EROFS 的块大小仍是页大小（4K），  
   于是 `i_blocks_per_folio(inode, folio) > 1`，iomap 的 ifs 双位图（`iomap_folio_state`）  
   随之启用，per-block uptodate/dirty 跟踪与 `read_bytes_pending` 的「先加满后减」机制开始工作——  
   一个 64K folio 只需部分块真正发 I/O，其余块被 `iomap_adjust_read_range()` 裁掉。  
   7.4 那笔提交的说明里「to support **sub-folio buffered I/Os** on file-backed mounts」说的正是这件事：  
   fileio 之前用自己的逻辑处理子页读，迁到 iomap 后这部分由框架接管。

### 5.2 局限与边界

* **两套读路径并存**：压缩（zdata 自研管线）与非压缩（iomap）是两套完全独立的读实现，  
  **连映射查询函数都不是同一个**——非压缩用 `erofs_map_blocks()`（`data.c`），  
  压缩用 `z_erofs_map_blocks_iter()`（`zmap.c`），  
  真正共享的只有更底层的 `erofs_read_metabuf()` / `erofs_map_dev()` 这些设施。  
  理解 EROFS 读路径必须先分清 datalayout。  
* **INLINE 的约定限制**：iomap 约定「单文件末尾只允许一个 INLINE extent」，  
  EROFS 的 tailpacking 恰好同构；  
  但 iomap 写路径的 `iomap_write_begin_inline()` 对「tailpacking 偏移非 0」直接 WARN——  
  只读的 EROFS 无所谓，若未来有写需求这是一个明确的坑位。  
* **DIO 仅限块设备后端**：fileio 模式 `s_bdev == NULL`，  
  O_DIRECT 静默退回 `filemap_read()`——  
  行为正确但排障时容易误判。

### 5.3 可借鉴之处

对想把自研只读/准只读文件系统接入 iomap 的后来者，EROFS 的路径几乎可以照抄：

1. 先实现 `->iomap_begin`（把自有映射翻译成 iomap type），  
   用 `iomap_bio_read_ops` 跑通块设备读；  
2. 有内联/元数据引用需要生命周期管理时，再配 `->iomap_end`；  
3. 报告型接口（fiemap/seek）单独做一套只读 ops，能不持资源就不带 end；  
4. 需要非块设备后端时，实现 `iomap_read_ops` 两个回调，遵守「成功即必须 `iomap_finish_folio_read`」的契约；  
5. 只读文件系统记得把 `release_folio` /  
   `invalidate_folio` 直接挂 `iomap_release_folio` /  
   `iomap_invalidate_folio`。

### 5.4 总结

EROFS 对 iomap 的运用是一个「契约设计良好时，接入方可以多么轻」的范本：  
**映射层**用 `erofs_iomap_begin` 把三种磁盘布局翻译成三种 iomap type；**  
执行层**在块设备上用 iomap 内置 bio 引擎、在文件后端上自研 `erofs_fileio_iomap_read_ops`；**  
压缩数据**认清 iomap 模型边界，读路径留在 zdata 自研管线，只在报告型接口上借道 iomap。  
v5.15 到 7.4 窗口的演进路线（DIO/DAX → 全量非压缩 → fiemap/seek → iomap_next 重构 → fileio 落地）  
显示：EROFS 几乎从不为 iomap 发明自己的东西，而是 **每当 iomap 长出新能力，  
就把自己的一块自研代码删掉**。

---

## 参考
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)  
[linux-stable (2f2f7eeef8b0)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  