---
layout:     post
title:      IOMAP 读路径
subtitle:   
date:       2026-11-10
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
---

# 03 · 读路径：从 `->read_folio` 到 bio 完成的全过程

> 前置知识：01.md 的映射语义、02.md 的迭代协议（`iomap_iter` 循环、`iomap_iter_advance`、`iomap_length`）；
> folio 与 page cache 的基本关系；bio 是块层 I/O 单位
> 难度：进阶
> 预计阅读时间：35 分钟

---

## 正文内容

### 1. 全景：FS 侧只有三行

以 EROFS 为例（`fs/erofs/data.c:404-432`），一个文件系统接入 buffered 读只需要这么点代码：

```c
static void erofs_read_folio(struct file *file, struct folio *folio)
{
    struct iomap_read_folio_ctx read_ctx = {
        .ops = erofs_is_fileio_mode(inode) ? &erofs_fileio_iomap_read_ops
                           : &iomap_bio_read_ops,
        .cur_folio = folio,
    };
    ...
    iomap_read_folio(&erofs_iomap_ops, &read_ctx, &iter_ctx);
}
```

readahead 版本结构完全一样，只是多填一个 `.rac`、改调 `iomap_readahead`。

三个角色分工要分清：

| 角色                   | 谁提供                                               | 干什么                                                     |
| ---------------------- | ---------------------------------------------------- | ---------------------------------------------------------- |
| `iomap_ops`            | **FS**                                               | 回答「这段文件在磁盘哪里」（01/02 篇）                     |
| `iomap_read_ops`       | **通用层默认**（`iomap_bio_read_ops`）或 **FS 覆盖** | 回答「怎么把这段读进来」（bio？还是别的？）                |
| `iomap_read_folio_ctx` | 调用者                                               | 本次读的上下文：当前 folio、rac、累计的 bio、fsverity 信息 |

**`iomap_read_ops` 是这棵树里比较新的抽象，也是读路径里最值得注意的设计**：它把「提交 I/O」这个动作也做了可插拔。   

默认实现走 bio（`fs/iomap/bio.c:119-122`），但 FS 可以替换成自己的传输方式——本树里的例子：

```
fs/iomap/bio.c:120     .read_folio_range = iomap_bio_read_folio_range   （默认）
fs/erofs/fileio.c:126  .read_folio_range = erofs_fileio_iomap_read_folio_range  （EROFS fileio 模式）
fs/fuse/file.c:1523    .read_folio_range = fuse_iomap_read_folio_range  （FUSE，走用户态）
```

EROFS 这里正好是个直观例子：**同一种映射，两种取数方式**。fileio 模式下「磁盘」其实是一个文件，不能用 bio 直接读块设备，于是换成文件读；映射逻辑（`erofs_iomap_ops`）完全不变。**这正是 iomap 契约的价值：把「在哪」和「怎么取」彻底分开。**

### 2. 两个入口：单 folio 与 readahead

```c
/* fs/iomap/buffered-io.c:651-684 */
void iomap_read_folio(const struct iomap_ops *ops,
        struct iomap_read_folio_ctx *ctx, void *private)
{
    struct iomap_iter iter = {
        .inode    = folio->mapping->host,
        .pos    = folio_pos(folio),
        .len    = folio_size(folio),      /* ← 范围就是一个 folio */
        .private = private,
    };
    ...
    while ((ret = iomap_iter(&iter, ops)) > 0)
        iter.status = iomap_read_folio_iter(&iter, ctx, &bytes_submitted);
    ...
    if (ctx->cur_folio)
        iomap_read_end(ctx->cur_folio, bytes_submitted);
}
```

`iomap_readahead()`（`:728`）差别只有两处：范围取自 `readahead_pos/length(rac)`，循环体换成 `iomap_readahead_iter()`——后者在每轮开始时判断「当前 folio 是否已经填完」，填完就 `iomap_read_end()` 收尾、再从 `rac` 取下一个 folio（`readahead_folio()`，`:699`）。

**关键观察：一次 `iomap_iter` 循环可以横跨多个 folio，一个 folio 也可以横跨多个 mapping。** 这是双向的多对多关系，也是读路径所有复杂度的来源。

### 3. 循环体：`iomap_read_folio_iter()` 的三岔口

`fs/iomap/buffered-io.c:557-649`。每拿到一段映射，先按 type 分岔：

```
iomap->type == IOMAP_INLINE  →  iomap_read_inline_data()  直接拷贝，不产生 I/O
否则                         →  ifs_alloc() 后进入逐块循环
```

**INLINE 分支**（`:418-442`）最省心：`folio_fill_tail()` 把 `iomap->inline_data` 拷进 folio，其余部分填零，`iomap_set_range_uptodate()` 一把标记完，然后 `iomap_iter_advance(iter, length)` 走人。**数据就在元数据里，根本不碰块设备**——还记得 01 篇里 EROFS 的 `iomap->inline_data = ptr` 吗？闭环在这里。

非 INLINE 分支进入内层 `while (length)` 循环，对每个块区间再分三岔（`:604-640`）：

```c
if ((iomap->flags & IOMAP_F_FSVERITY) && iomap->type == IOMAP_HOLE) {
    /* ① fsverity 的 merkle tree 区块：合成零哈希，不读盘 */
} else if (iomap_block_needs_zeroing(iter, pos)) {
    /* ② 需要填零：hole / 新分配的块 / 超出 i_size 的部分 */
    folio_zero_range(folio, poff, plen);
    iomap_set_range_uptodate(folio, poff, plen);
} else {
    /* ③ 真读：交给 read_ops->read_folio_range() */
    ret = ctx->ops->read_folio_range(iter, ctx, plen);
    *bytes_submitted += plen;
    if (*bytes_submitted == folio_len || !ifs)
        ctx->cur_folio = NULL;      /* ← 所有权移交 */
}
```

第 ② 岔用的是 `iomap_block_needs_zeroing()`（`:382-407`），它的判断顺序值得记：

- `srcmap->type != IOMAP_MAPPED` → 填零（hole、delalloc、unwritten **都在这里被填零**，01 篇那个「unwritten 读出来必须是零」的承诺就是这一行兑现的）
- `srcmap->flags & IOMAP_F_NEW` → 填零（刚分配，盘上是垃圾）
- `pos >= i_size` → 填零（EOF 之后）
- 例外：`IOMAP_F_FSVERITY` 的数据**不填零**（verity 元数据在 i_size 之后，必须真读）

第 ③ 岔末尾那句 `ctx->cur_folio = NULL` 是理解整个读路径的钥匙：**一旦整个 folio 都提交了 I/O，这个 folio 的所有权就移交给 I/O 完成回调了**，循环体不再碰它，也由完成回调负责 `folio_end_read()`。

### 4. `iomap_adjust_read_range()`：为什么不能整段照读

`fs/iomap/buffered-io.c:318-380`。拿到 `[pos, pos+length)` 之后不能直接提交，要先「裁剪」：

```c
size_t poff = offset_in_folio(folio, *pos);
size_t plen = min_t(loff_t, folio_size(folio) - poff, length);   /* ① 裁到 folio 边界 */
...
if (ifs) {
    next = ifs_next_nonuptodate_block(folio, first, last);    /* ② 跳过前面已 uptodate 的块 */
    blocks_skipped = next - first;
    if (blocks_skipped) { *pos += ...; plen -= ...; }
    ...
    next = ifs_next_uptodate_block(folio, next, last);        /* ③ 裁掉尾部已 uptodate 的块 */
}
if (orig_pos <= isize && orig_pos + orig_plen > isize) {          /* ④ i_size 分界 */
    ...
}
```

四个裁剪动作，各自解决一个真实问题：

1. **裁到 folio 边界**：一次 I/O 不能跨 folio（bio 是按 folio 内的页装配的）。
2. **跳过前段已 uptodate 的块**：块大小 < folio 大小时，一个 folio 里可能有一部分块已经读过（比如上次只读了其中两块）。**不跳过就会重复读盘**。
3. **裁掉尾部已 uptodate 的块**：同理，避免把已经有效的块再读一遍。
4. **i_size 分界**：跨越 i_size 的那个块要拆成两半处理——i_size 之前读盘、之后填零，「因为 page cache 可能已被 mmap 映射，EOF 之后的内容必须是零」。

第 2、3 条引出一个必须理解的结构：**ifs**。

### 5. ifs：large folio 下的「逐块状态」

`fs/iomap/buffered-io.c:22-33`：

```c
struct iomap_folio_state {
    spinlock_t        state_lock;
    unsigned int        read_bytes_pending;
    atomic_t        write_bytes_pending;

    /*
     * Each block has two bits in this bitmap:
     * Bits [0..blocks_per_folio) has the uptodate status.
     * Bits [b_p_f...(2*b_p_f))   has the dirty status.
     */
    unsigned long        state[];
};
```

它挂在 `folio->private` 上，本质是一个 **per-block 的 2-bit 位图**（每块 1 bit uptodate + 1 bit dirty）+ 两个「还有多少字节在飞」的计数器。

**为什么需要它？** 因为 folio 可以比块大得多（large folio：64K folio 配 4K 块就是 16 块）。这时「这个 folio 是否 uptodate」不再是布尔量——可能出现「前 3 块有效、后面 13 块没读」的中间态。而旧的 buffer_head 方案是用 per-block 的结构体数组来表达，代价是内存和复杂度。ifs 用位图解决了同一问题，代价低得多。

围绕它的一整套 helper 都在这个文件前半部分：`ifs_set_range_uptodate()`、 `ifs_next_uptodate_block()`、`ifs_next_nonuptodate_block()`、`ifs_is_fully_uptodate()` 等。

### 6. 「谁负责结束这次读」：read_bytes_pending 的移交协议

这是读路径最微妙的一段。一个 folio 可能被切成多次 I/O 提交（因为块状态不连续、或映射不连续），所以必须有个机制判断「最后一次 I/O 完成时才 `folio_end_read()`」。

iomap 的做法是**先乐观地按整个 folio 记账，再把没提交的部分减掉**：

```c
/* iomap_read_init(): buffered-io.c 约 480-499 */
ifs->read_bytes_pending = folio_size(folio);     /* ① 先假定整个 folio 都要读 */
```

```c
/* iomap_read_end(): buffered-io.c:510-555，本轮 I/O 提交完毕后调用 */
ifs->read_bytes_pending -= folio_size(folio) - bytes_submitted;  /* ② 扣掉跳过未提交的部分 */
end_read = !ifs->read_bytes_pending;
if (end_read)
    folio_end_read(folio, uptodate);
```

而每次 bio 完成时，`iomap_finish_folio_read()`（`:444-470`）做相反方向的事：

```c
if (error) ...
if (ifs) {
    uptodate = ifs_set_range_uptodate(folio, ifs, off, len);
    ifs->read_bytes_pending -= len;              /* ③ 每完成一段就减去 */
    finished = !ifs->read_bytes_pending;
}
if (finished)
    folio_end_read(folio, uptodate);
```

于是有两种收尾路径：

- **提交了 I/O**：由 I/O 完成回调（`iomap_read_end_io` → `iomap_finish_folio_read`）在计数归零时收尾；
- **一个字节都没提交**（整段都是填零或已 uptodate）：`iomap_read_end()` 在 ② 里把计数扣到 0，当场收尾。

**`ctx->cur_folio = NULL` 这个动作就是「所有权移交」的标记**：置空之后循环体不再持有 folio，`iomap_read_folio()` 末尾的 `if (ctx->cur_folio) iomap_read_end(...)` 也就不会再重复收尾一次。

#### 一个容易踩的并发细节：`folio_mark_uptodate()` 不能随便调

`iomap_set_range_uptodate()`（`buffered-io.c:81-108`）里有一段必须知道的判断：

```c
if (folio_test_uptodate(folio))
    return;

if (ifs) {
    spin_lock_irqsave(&ifs->state_lock, flags);
    /*
     * If a read with bytes pending is in progress, we must not call
     * folio_mark_uptodate(). The read completion path (iomap_read_end())
     * will call folio_end_read(), which uses XOR semantics to set the
     * uptodate bit. If we set it here, the XOR in folio_end_read() will
     * clear it, leaving the folio not uptodate.
     */
    mark_uptodate = ifs_set_range_uptodate(folio, ifs, off, len) &&
            !ifs->read_bytes_pending;
    spin_unlock_irqrestore(&ifs->state_lock, flags);
}

if (mark_uptodate)
    folio_mark_uptodate(folio);
```

要点：**当还有读 I/O 在飞（`read_bytes_pending != 0`）时，即使位图显示所有块都 uptodate，也不能调用 `folio_mark_uptodate()`**。因为 `folio_end_read()` 是用 **XOR 语义**置位的——提前置 1，XOR 会把它清成 0，结果 folio 反而不是 uptodate。

这解释了第 6 节里为什么必须由「最后一个完成者」来收尾：**pending 计数不只是「谁负责收尾」，它还保护着 folio 标志位的正确性。** 任何想在读进行中手动标 uptodate 的代码（比如某些 FS 的自定义 `read_folio_range`）都必须走 `iomap_set_range_uptodate()`，不能自己 `folio_mark_uptodate()`。

### 7. bio 是怎么攒起来的

默认 `iomap_read_ops` 走 bio（`fs/iomap/bio.c:104-122`）：

```c
int iomap_bio_read_folio_range(const struct iomap_iter *iter,
        struct iomap_read_folio_ctx *ctx, size_t plen)
{
    struct bio *bio = ctx->read_ctx;

    if (!bio ||
        bio_end_sector(bio) != iomap_sector(&iter->iomap, iter->pos) ||   /* ① 必须物理连续 */
        !iomap_bio_has_room(&iter->iomap, bio, plen) ||                    /* ② 还有空间 */
        !bio_add_folio(bio, folio, plen, offset_in_folio(folio, iter->pos)))
        iomap_read_alloc_bio(iter, ctx, plen);                          /* 否则开新 bio */
    return 0;
}
```

三个合并条件里第 ① 条最重要，也最能体现 iomap 的价值：**`bio_end_sector(bio) != iomap_sector(iomap, iter->pos)` 就直接开新 bio**。也就是说「能不能合并」完全由映射给出的物理位置决定——FS 只要把 extent 如实报告成一个大的 `iomap->length`，多个 folio 就自动合成一个大 bio；反之，extent 碎了，I/O 也就跟着碎。**I/O 合并质量是映射报告质量的直接函数。**

`iomap_read_alloc_bio()`（`:66-102`）里还有两个细节值得一看：

- `bio_alloc_bioset()` 失败后**退回单页 bio** 再试一次（`:90-94`），避免在内存紧张时整次读失败；
- `bio->bi_iter.bi_sector = iomap_sector(iomap, iter->pos)`（`:97`）——01 篇那个换算式在这里派上用场。

最后 `submit_read` 由调用方在每轮循环后触发（`:53-57` → `iomap_bio_submit_read_endio()`，完成回调设为 `iomap_read_end_io`，即第 6 节的收尾路径）。

### 8. 一句话总结与常见误区

读路径可以压缩成：**映射 → 按 type 分岔（拷贝 / 填零 / 真读）→ 按块状态与 i_size 裁剪 → 攒 bio → 由完成回调收尾**。

三个最容易错的地方：

1. **以为「hole 就不会有 I/O」是对的，但「delalloc / unwritten / 新分配块」同样走填零**——判断函数是 `iomap_block_needs_zeroing()`，不是 `type == IOMAP_HOLE`。
2. **以为一次读只对应一个映射**。实际上 folio 与 mapping 是多对多，ils 位图和 `read_bytes_pending` 的存在就是为了处理这种交错。
3. **以为填零是 FS 的事**。**填零在通用层**（`folio_zero_range()`），FS 只负责如实报告 type 和 flags。

---

## 思考题

1. `iomap_read_folio_iter()` 里处理 `IOMAP_INLINE` 时有一句 `if (offset > 0) ifs_alloc(...)`（`:436-437`），而 `iomap_read_inline_data()` 随后却把「从 offset 到 folio 末尾」全部标记成 uptodate（`:440`）。为什么 offset 为 0 时不需要分配 ifs，offset 大于 0 时就需要？（提示：想想 ifs 是 per-block 位图，以及整 folio 都 effective 时 folio 自身的 uptodate 标志够不够用。）

2. 假设一个文件的块大小是 4K、folio 大小是 64K，且第 0、1、2 块已经是 uptodate，其余需要读。走一遍 `iomap_adjust_read_range()`：它跳过了多少字节？`iomap_read_end()` 里 `read_bytes_pending` 最终被扣成多少？如果 FS 报告 `IOMAP_F_BOUNDARY`，会不会改变这次裁剪的结果？

3. EROFS 在 fileio 模式下把 `read_folio_range` 换成自己的实现（`fs/erofs/fileio.c:126`），但 `iomap_ops` 不变。请说明：这次替换之后，下面这些机制是否仍然照常工作——（a）hole 的填零、（b）INLINE 数据、（c）`read_bytes_pending` 的收尾协议、（d）bio 合并。哪个会失效？（如果你熟悉 erofs 的 fileio 路径，可以顺手对比一下它和 bio 路径在失败处理上的差异。）

### 参考答案

**第1题：** INLINE 读时为什么 `offset == 0` 不用分配 ifs，`offset > 0` 就要？

> 看 `iomap_read_inline_data()` 收尾那句（`fs/iomap/buffered-io.c:439-440`）：
>
> ```c
> folio_fill_tail(folio, offset, iomap->inline_data, size);
> iomap_set_range_uptodate(folio, offset, folio_size(folio) - offset);
> ```
>
> 标记 uptodate 的范围是 `[offset, folio 末尾)`。
>
> - **`offset == 0`**：标记范围覆盖**整个 folio**，于是 folio 直接被置成 `folio_test_uptodate()`——一个布尔量就够表达全部状态，不需要 per-block 位图。
> - **`offset > 0`**：只有后半段被标记，前半段 `[0, offset)` 属于**前一个 mapping**（在上一次 iter 循环里处理过）。此时整 folio 不是「全有或全无」的状态，**必须用 per-block 位图记下「哪些块有效」**，所以要 `ifs_alloc()`。
>
> 一句话：**ifs 只在 folio 的状态无法用一个布尔量表达时才需要**。`__iomap_write_begin()` 里有完全相同的判断（`buffered-io.c:895-897`）：如果这次写覆盖整个 folio，直接 `return 0` 不分配 ifs。这个「能省就省」的模式在 iomap 里反复出现。

**第2题：** 4K 块 / 64K folio、第 0~2 块已 uptodate，走一遍 `iomap_adjust_read_range()`；`read_bytes_pending` 最后是多少？`IOMAP_F_BOUNDARY` 会改变裁剪结果吗？

> 16 个块。`poff = 0`、`plen = 65536`，`first = 0`、`last = 15`。
>
> 1. **跳过前段**：`ifs_next_nonuptodate_block(folio, 0, 15)` 返回 **3**，`blocks_skipped = 3`，`block_offset = pos & 4095 = 0`，故 `bytes_skipped = (3 << 12) - 0 = 12288`。于是 `pos += 12248→12288`、`poff = 12288`、`plen = 65536 - 12288 = 53248`，`first = 3`。
> 2. **裁尾段**：`next = 4`；若第 4~15 块都不是 uptodate，`ifs_next_uptodate_block(4, 15)` 返回 16 > last，**不裁剪**。
> 3. **i_size 分界**：假设 isize 不落在这个 folio 内，不裁剪。
>
> 最终 `poff = 12288`、`plen = 53248`（13 个块，即第 3~15 块）。
>
> `read_bytes_pending`：`iomap_read_init()` 先乐观记成 **65536**；提交 53248 字节后，`iomap_read_end()` 扣掉 `folio_size - bytes_submitted = 12288`，**剩 53248 ≠ 0**，所以**不在 `iomap_read_end()` 里收尾**，交给 I/O 完成回调在计数归零时 `folio_end_read()`。这正是上一节说的「所有权移交」。
>
> **`IOMAP_F_BOUNDARY` 不改变裁剪结果。** 它不参与 `iomap_adjust_read_range()` 的任何判断；本树里它唯一的消费者在写回路径——`fs/iomap/ioend.c:194`，用来阻止 ioend 跨过这个映射边界继续合并。所以它是**写回侧的 I/O 切分信号**，不是读路径的裁剪信号。

**第3题：** EROFS fileio 模式换掉 `read_folio_range` 后，(a)(b)(c)(d) 哪些照常、哪些失效？

> - **(a) hole 填零 —— 照常。** 填零在通用层 `folio_zero_range()`（`:612`），由 `iomap_block_needs_zeroing()` 判断，与 `read_ops` 无关。
> - **(b) INLINE 数据 —— 照常。** `iomap_read_inline_data()` 在循环体分岔口，压根不经过 `read_ops`。
> - **(c) `read_bytes_pending` 收尾协议 —— 照常，但调用责任转移到 FS**。协议本身在通用层，fileio 的实现必须自己在 I/O 完成时调用 `iomap_finish_folio_read()`——它确实这么做了（`fs/erofs/fileio.c:34`）。
> - **(d) bio 合并 —— 失效（不再适用）。** fileio 模式下「磁盘」其实是一个文件，没有块设备可提交，也就没有 `bio_end_sector` 连续性可谈。合并逻辑换成 fileio 自己的（它自己维护一个小 bio 装 bvec，`fileio.c:10-11`）。
>
> **结论：换掉 `read_ops` 只影响「怎么把字节搬进 folio」，不影响「要不要读、要不要填零、什么时候收尾」。** 这就是这套抽象切得好不好的检验标准。
