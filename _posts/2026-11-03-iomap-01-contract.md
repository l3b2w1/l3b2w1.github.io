---
layout:     post
title:      IOMAP的契约
subtitle:   
date:       2026-11-03
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
---

# 01 · iomap 的契约：把「文件偏移在哪里」变成一个可迭代的映射

> 前置知识：页缓存与 `address_space`、folio 的基本概念、extent（逻辑块区间→物理块区间）的含义、bio 是块层 I/O 的基本单位
> 难度：进阶
> 预计阅读时间：25 分钟

## 一、先说问题：iomap 出现之前

一个文件系统想在 Linux 里支持读写，以前要自己写满一整套 `address_space_operations`：

```
.read_folio / .readahead  —— 自己查 extent，自己提交 bio
.writepages               —— 自己找脏页，自己分配块，自己提交
.bmap / .fiemap           —— 自己再查一遍
.seek_hole / .seek_data   —— 还得再查一遍
```

于是每个文件系统都在重复做同一件事：**把「文件的某段逻辑偏移」翻译成「磁盘上的某段物理位置」**，然后再各自接上 folio、bio、写回、错误处理。   

更麻烦的是，这套写法长期和 **`buffer_head`** 绑在一起——一个以块大小为粒度、把每个块缓存状态挂在页上的结构。它带来三个后果：  

1. **映射逻辑与页缓存机制纠缠**：读写路径里塞满了 FS 私有的映射判断，通用层没法复用。
2. **块大小绑定**：一个页被切成若干 buffer_head，大块（large folio）、原子写、大粒度 I/O 都很难表达。
3. **每个新接口都要重写一遍遍历**：FIEMAP、SEEK_HOLE、DIO、unshare 各写各的偏移遍历循环，且各自维护一套边界处理。

**iomap 做的事，一句话：把「翻译」这一步单独抽成一个契约，遍历由通用层统一做。**

> **契约**：文件系统只负责回答一个问题——「文件 `[offset, offset+length)` 这段，在磁盘上是什么？」。  
>
> 答案用一个 `struct iomap` 表达。至于拿到答案后怎么读、怎么写、怎么提交 bio、怎么回写，全部由 `fs/iomap/` 下的通用代码完成。

这带来的直接收益：FS 侧只需要实现少数回调，`read_folio`、readahead、buffered write、DIO、FIEMAP、SEEK_HOLE、zero range、truncate 全部免费获得，且**遍历逻辑只有一份，边界只处理一次**。

## 二、契约的载体：`struct iomap`

定义在 `include/linux/iomap.h:130-141`：

```c
struct iomap {
    u64            addr;   /* disk offset of mapping, bytes */
    loff_t            offset; /* file offset of mapping, bytes */
    u64            length; /* length of mapping, bytes */
    u16            type;   /* type of mapping */
    u16            flags;  /* flags for mapping */
    struct block_device    *bdev;  /* block device for I/O */
    struct dax_device    *dax_dev;
    void            *inline_data;
    void            *private;        /* filesystem private */
    u64            validity_cookie; /* used with .iomap_valid() */
};
```

六个核心字段要读成一句话：**从文件偏移 `offset` 开始的 `length` 个字节，位于 `bdev` 上从 `addr` 开始的位置，这段映射的性质是 `type`，附带属性是 `flags`。**  

注意这个设计的两个关键选择：

- **`addr` 是字节偏移，不是块号。** 这是刻意摆脱 buffer_head 的块粒度绑定：iomap 不关心 FS 的块大小，只回答字节位置。转换发生在需要时：

  ```c
  /* include/linux/iomap.h:143-148 */
  static inline sector_t iomap_sector(const struct iomap *iomap, loff_t pos)
  {
          if (iomap->flags & IOMAP_F_ANON_WRITE)
                  return U64_MAX; /* invalid */
          return (iomap->addr + pos - iomap->offset) >> SECTOR_SHIFT;
  }
  ```

  换算式是 `sector = (addr + pos - offset) >> 9`。也就是说 **iomap 描述的是一段区间，而不是单个位置**：任何时候想知道某个具体 `pos` 的磁盘位置，都要用「段起点 + 段内偏移」现算。

- **`length` 是「这一段能一口气走多远」，不是请求的总长度。** FS 可以返回比请求更短的映射（下一段映射性质不同、撞上 extent 边界等），推进的责任在通用层——这是下一篇的核心。

### `addr` 的一个魔法值

```c
/* include/linux/iomap.h:128 */
#define IOMAP_NULL_ADDR -1ULL    /* addr is not valid */
```

`addr` 为 `IOMAP_NULL_ADDR` 时表示「这段没有有效磁盘位置」。   

它和 `type` 配合使用：hole、delalloc 这些「还没落到盘上」的映射都会把它置成这个值。

## 三、type：这段映射「是什么性质」

`include/linux/iomap.h:31-35` 定义了五种（注意它们是普通 `#define` 的数值 0~4，不是位标志）：

| type                  | 含义                                                      | `addr` 是否有效              |
| --------------------- | --------------------------------------------------------- | ---------------------------- |
| `IOMAP_HOLE (0)`      | 没有分配块，需要分配                                      | 否（通常 `IOMAP_NULL_ADDR`） |
| `IOMAP_DELALLOC (1)`  | 延迟分配块，位置尚未确定                                  | 否                           |
| `IOMAP_MAPPED (2)`    | 已分配，`addr` 处有数据                                   | **是**                       |
| `IOMAP_UNWRITTEN (3)` | 已分配但处于 unwritten 状态（读出来应是零，写入后需转换） | 是（占位）                   |
| `IOMAP_INLINE (4)`    | 数据内联在 inode/元数据里，不在独立数据块                 | 否，改用 `inline_data`       |

`IOMAP_UNWRITTEN` 值得单独想一下：它是「空间已经占了，但内容还没写」的状态。   

这个状态存在的理由是**对读和对写的语义不同**——读它必须返回零（不能把盘上残留数据暴露给用户），   

写它则需要在写完后把状态转成 `IOMAP_MAPPED`（即 FS 的「转换 unwritten extent」操作）。   

**同一个 type 在读路径和写路径上行为不同**，这是理解 iomap 写路径的钥匙之一。   

`IOMAP_INLINE` 也不走 bio：数据就在元数据里，通用层通过 `iomap_inline_data()`（`iomap.h:153-156`，即 `inline_data + pos - offset`）直接拷。

## 四、两类标志千万别混

这是最容易踩的坑——iomap 里有**两组完全不同的「flags」**，名字相近，语义无关：

**① 传入回调的 `IOMAP_*`**：描述「我这次要干什么」（`iomap.h:200-214`）

```c
#define IOMAP_WRITE        (1 << 0)  /* 写，可能需要分配块 */
#define IOMAP_ZERO        (1 << 1)  /* 填零操作，可以跳过 hole */
#define IOMAP_REPORT        (1 << 2)  /* 只是报告状态，如 FIEMAP */
#define IOMAP_FAULT        (1 << 3)  /* 为缺页而映射 */
#define IOMAP_DIRECT        (1 << 4)  /* 直接 I/O */
#define IOMAP_NOWAIT        (1 << 5)  /* 不允许阻塞 */
#define IOMAP_OVERWRITE_ONLY    (1 << 6)  /* 只允许纯覆盖，不许分配 */
#define IOMAP_UNSHARE        (1 << 7)  /* unshare_file_range */
#define IOMAP_ATOMIC        (1 << 9)  /* 防撕裂写 */
#define IOMAP_DONTCACHE        (1 << 10)
```

**② 映射自身的 `IOMAP_F_*`**：描述「这段映射有什么属性」（`iomap.h:75-123`）

```c
#define IOMAP_F_NEW        (1U << 0)  /* 本次刚分配的，需要转换 */
#define IOMAP_F_DIRTY        (1U << 1)  /* 脏，回写时需要特殊处理 */
#define IOMAP_F_SHARED        (1U << 2)  /* 与别的文件共享（reflink），写前需 COW */
#define IOMAP_F_MERGED        (1U << 3)  /* 多个 extent 合并而来 */
#define IOMAP_F_XATTR        (1U << 5)
#define IOMAP_F_BOUNDARY    (1U << 6)  /* 到此为止，别再往后合并 I/O */
#define IOMAP_F_STALE        (1U << 15) /* 映射已失效，需要重新取 */
```

第一组是**请求者对 FS 说的**（你要给我一个能写的映射），第二组是**FS 对请求者说的**（这段是共享的，别直接覆盖）。方向相反，别搞混。

## 五、一个真实实例：EROFS 怎么回答这个问题

本树里用 iomap 的文件系统不少，可以 grep 验证：

```
fs/erofs/data.c:288    erofs_iomap_begin
fs/gfs2/bmap.c:1102    gfs2_iomap_begin
fs/ntfs3/inode.c:940   ntfs_iomap_begin
fs/btrfs/direct-io.c:369  btrfs_dio_iomap_begin
fs/f2fs/data.c:4770    f2fs_iomap_begin
```

你手边最熟的是 EROFS，正好是最干净的只读示例（`fs/erofs/data.c:288-353`，注释是我加的）：

```c
static int erofs_iomap_begin(struct inode *inode, loff_t offset, loff_t length,
        unsigned int flags, struct iomap *iomap, struct iomap *srcmap)
{
    ...
    map.m_la = offset;      /* ① 把 requests 翻译成 FS 自己的映射请求 */
    map.m_llen = length;
    ret = erofs_map_blocks(realinode, &map);   /* ② 走 EROFS 自己的映射逻辑 */
    if (ret < 0)
        return ret;

    iomap->offset = map.m_la;    /* ③ 把 FS 的答案填回契约 */
    iomap->length = map.m_llen;
    iomap->flags = 0;
    iomap->addr = IOMAP_NULL_ADDR;

    if (!(map.m_flags & EROFS_MAP_MAPPED)) {   /* ④ 没映射 → hole */
        iomap->type = IOMAP_HOLE;
        return 0;
    }
    ...
    iomap->bdev = mdev.m_bdev;                 /* ⑤ 物理位置 = 设备偏移 + 段内地址 */
    iomap->addr = mdev.m_dif->fsoff + mdev.m_pa;

    if (map.m_flags & EROFS_MAP_META) {        /* ⑥ 元数据内联 */
        iomap->type = IOMAP_INLINE;
        ...
        iomap->inline_data = ptr;
    } else {
        iomap->type = IOMAP_MAPPED;
    }
    return 0;
}
```

把它抽象出来，**任何文件系统的 `iomap_begin` 都是同一个五步形状**：

1. 把 `(offset, length, flags)` 翻译成自己内部能懂的映射请求；
2. 调用自己的映射/分配逻辑（EROFS 是 `erofs_map_blocks`，XFS 是 `xfs_bmapi_*`，Btrfs 走 extent map）；
3. 把结果写回 `iomap->offset / length`；
4. 决定 `type`，并按 type 决定填 `addr`、还是 `inline_data`、还是 `IOMAP_NULL_ADDR`；
5. 填 `bdev`（或 `dax_dev`），以及可选的 `private` / `validity_cookie`。

第 ⑤ 步里 `fsoff + m_pa` 这个加法值得记住：iomap 的 `addr` 是**相对某个 block_device 的字节偏移**，   

FS 的「设备内偏移」要先叠加它自己在该设备上的起始偏移，才能交出去。    

凡是 FS 支持「镜像内多设备 / 数据在设备上的某个偏移之后」这类布局，这一步就是坑点所在。

在 7.4 这棵树里，注册方式是新的（`fs/erofs/data.c:374-379`）：

```c
static DEFINE_IOMAP_ITER_NEXT_END(erofs_iomap_next, erofs_iomap_begin,
                  erofs_iomap_end);

static const struct iomap_ops erofs_iomap_ops = {
    .iomap_next = erofs_iomap_next,
};
```

即 FS 填一个 `struct iomap_ops`（`iomap.h:242-246`），里面挂 `iomap_begin` / `iomap_end` / `iomap_next` 三个回调。   

EROFS 只用了 `iomap_next` 一个入口——为什么现在流行这种写法、老的 begin/end 双回调在哪里还能见到，是下一篇的主题。

## 六、契约的另一端：谁来用这些映射

FS 交出 `iomap_ops` 之后，`fs/iomap/` 下那一套通用实现就都活了。当前树里的入口：

| 功能                   | 入口                                         | 文件                                    |
| ---------------------- | -------------------------------------------- | --------------------------------------- |
| buffered 读单页 / 预读 | `iomap_read_folio` / `iomap_readahead`       | `fs/iomap/buffered-io.c:651` / `:728`   |
| buffered 写            | `iomap_file_buffered_write`                  | `fs/iomap/buffered-io.c:1295`           |
| 写回                   | `iomap_writepages` / `iomap_writeback_folio` | `fs/iomap/buffered-io.c:2075` / `:1985` |
| 缺页写                 | `iomap_page_mkwrite`                         | `fs/iomap/buffered-io.c:1859`           |
| 直接 I/O               | `iomap_dio_rw`                               | `fs/iomap/direct-io.c`                  |
| FIEMAP                 | `iomap_fiemap`                               | `fs/iomap/fiemap.c`                     |
| SEEK_HOLE/DATA         | `iomap_seek_hole` / `iomap_seek_data`        | `fs/iomap/seek.c`                       |
| 填零 / 截断块          | `iomap_zero_range` / `iomap_truncate_page`   | `fs/iomap/buffered-io.c:1745` / `:1796` |
| unshare                | `iomap_file_unshare`                         | `fs/iomap/buffered-io.c:1617`           |

一个 FS 实现一组回调，换来上面整张表——这就是 iomap 的全部价值主张。

## 思考题

1. `iomap_sector()` 用 `(addr + pos - offset) >> 9` 现算扇区号，而不是让 `iomap_begin` 直接填「pos 对应的扇区号」。如果让 FS 直接填 pos 对应的位置，会失去什么能力？（提示：想想一次映射要覆盖多个 folio 的情形，以及 `IOMAP_F_BOUNDARY` 存在的理由。）

2. `IOMAP_UNWRITTEN` 状态的空间已经分配了。读一个 unwritten 区间应当返回零，但盘上可能残留旧数据——这个「读出来是零」的保证，应该由 FS 侧回调还是 iomap 通用层来实现？为什么把它设计成 `type` 而不是一个 `flags`？

3. `iomap->length` 允许比请求长度短。设想一次覆盖 3 个不同 extent 的读请求：谁负责推进到下一个 extent？如果 FS 的 `iomap_begin` 返回 `length == 0`，通用层会怎么反应？（可以翻一下 `fs/iomap/iter.c:37-40` 的三个 `WARN_ON_ONCE`，它们其实在声明一组不变量。）

### 参考答案

**第1题：** 为什么 `iomap_begin` 填「段起点 + 段长度」，而不是直接填「pos 对应的磁盘位置」？

> 因为**一次映射要服务许多个 pos**。一次 readahead 可能横跨几十个 folio，如果每个 folio 都回调一次 FS，映射查询的成本会翻几十倍，而且 FS 每次都要重新走一遍 extent 查找。填成区间后，通用层对每个 folio 用 `iomap_sector(iomap, pos)` 现算即可，FS 的回调次数只与「extent 个数」挂钩，不与「folio 个数」挂钩。
>
> 第二层原因是**合并 I/O 的能力**：bio 想合并多个 folio 的连续 I/O，前提是通用层知道「这一段在盘上是否连续」。区间表达天然给出这个信息；单点表达则每次都要回头问 FS。`IOMAP_F_BOUNDARY` 正是 FS 用来说「到我这里为止，别再往后合并」的反向信号。

**第2题：** unwritten 区间「读出来是零」的保证，归 FS 还是通用层？为什么它是 `type` 而不是 `flags`？

> **读路径的零填充归通用层**：`iomap` 只需要告诉通用层「这段是 UNWRITTEN」，通用层在读路径上把对应范围填零而不提交 bio（具体位置在读路径篇展开）。FS 的责任是**状态本身**：分配时把 extent 标成 unwritten，写完成后把它转成 `MAPPED`（这个转换只能在 FS 侧做，因为它要改自己的 extent map）。
>
> 它必须是 `type` 而不是 `flags`，因为 `type` 是**互斥的类别**（一段区间不可能同时是 HOLE 和 MAPPED），而 `flags` 是**可叠加的属性**。unwritten 与 mapped 是同一维度的两种状态，互相排斥，所以进 `type`。反过来想：如果它是个 flag，那 `IOMAP_MAPPED | IOMAP_F_UNWRITTEN` 和 `IOMAP_UNWRITTEN` 就有了两种写法，语义立刻分裂。

**第3题：** `iomap->length` 可以比请求短，谁负责推进到下一段？`length == 0` 会怎样？

> 推进的责任在**通用层的迭代器**，不在 FS。FS 只保证「我返回的这一段是自洽的、可以一口气处理的」；通用层处理完这一段后，调 `iomap_iter_advance()` 把 `iter->pos` 往前推，再向 FS 要下一段。这就是本篇的主题。
>
> 至于 `length == 0`：`fs/iomap/iter.c:35-47` 的 `iomap_iter_done()` 里有一条 `WARN_ON_ONCE(iter->iomap.length == 0)`。也就是说 FS 返回零长度映射属于**违约**——迭代器要求每次产出的映射必须覆盖当前 `pos` 且长度非零，否则循环无法前进。这条 WARN 与另外两条一起构成了迭代器的不变量，下面正文第 3 节展开。
