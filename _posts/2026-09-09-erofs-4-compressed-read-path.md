---
layout:     post
title:      EROFS compressed reading-path
subtitle:   EROFS 压缩读路径
date:       2026-09-09
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 阶段 4：压缩读路径

> 这是全套材料最难的一章，也是最有价值的一章。
> 压缩相关代码（`zmap.c` + `zdata.c` + `zutil.c`）占全树约 33%。
>
> 建议分三步走：先看 zmap（映射），再看 zdata（状态机），
> 最后看两者如何联动。**不要试图一次读懂整个压缩路径。**

## 本阶段目标

读完这一章，你应该能够：

1. 解释为什么压缩文件的"逻辑偏移 → 物理位置"不能靠算术，必须查索引
2. 区分 **lcluster**（逻辑簇）与 **pcluster**（物理簇），说清它们为什么不是一一对应
3. 说出压缩索引的三种格式与 HEAD / NONHEAD 两种索引项类型
4. 读懂 `z_erofs_map_blocks_fo()` 的主流程
5. **解释 pcluster 为什么必须有状态机**（并发去重解压）
6. 说清 in-place 解压与 cached 解压的差别，以及 in-place 为什么需要 margin
7. 解释 `m_pa` 为什么是字节地址、为什么不保证块对齐

## 4.1 为什么压缩不能做算术

![压缩 vs 非压缩](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-09-erofs-09-compressed-vs-plain.svg)

非压缩时，逻辑偏移到物理位置是个除法：

```c
/* 阶段 3 的 erofs_map_blocks，data.c */
map->m_pa = erofs_pos(sb, vi->startblk) + map->m_la;
```

压缩后**这个等式不成立**，因为压缩后长度不定。

阶段 1 的实测数据说明了问题有多极端：

| 文件 | 原始大小 | 磁盘占用 | 比例 |
|---|---|---|---|
| `rep.txt` | 400000 字节 | 4096 字节 | **1.02%** |
| `big.txt` | 3000000 字节 | 12288 字节 | **0.41%** |

同一个文件，逻辑 8KB 对应的物理位置可能是 100 字节之后，也可能是 10000 字节之后。
**没有算术解，只能查表。**

那张表就是**压缩索引**，它存在 inode 后面（datalayout 1/3 时）。


## 4.2 lcluster 与 pcluster

这是压缩路径最基础的一对概念：

| | lcluster（逻辑簇） | pcluster（物理簇） |
|---|---|---|
| 全称 | logical cluster | physical cluster |
| 是什么 | 压缩**前**的固定长度块 | 一次解压的**物理单位** |
| 大小 | 通常 4K 的倍数（`z_lclusterbits`） | 不定（压缩后多长就多长） |
| 谁定义 | 格式规定，固定 | mkfs 决定 |
| 数量关系 | **一个 pcluster 解压后可能覆盖多个 lcluster** | |

**关键认知：lcluster 与 pcluster 不是一一对应的。**

```
逻辑视图（lcluster，等长）：
  ┌────┬────┬────┬────┬────┐
  │ L0 │ L1 │ L2 │ L3 │ L4 │
  └────┴────┴────┴────┴────┘
    ↓    ↓              ↓
物理视图（pcluster，不等长）：
  ┌─────────────┬──────────┐
  │   P0        │   P1     │      P0 解压后覆盖 L0~L3
  └─────────────┴──────────┘      P1 覆盖 L4
```

这个"一对多"的关系，是后面所有复杂性的根源：

- 索引只需要给 **pcluster 的头** 记物理地址
  （中间的 lcluster 不记，标记成 NONHEAD）
- 从中间某个 lcluster 出发，要**往回找**它属于哪个 pcluster


## 4.3 压缩索引：三种格式，两类索引项

![索引格式](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-09-erofs-10-zmap-index-formats.svg)

#### 三种格式

索引本身也占空间，所以有三种格式，mkfs 按需要选择
（用 `z_advise` 里的标志位告诉内核该用哪种）：

| 格式 | 每项大小 | 优点 | 缺点 |
|---|---|---|---|
| **完整索引**（non-compacted） | 16 字节 | 直接、无限制 | 占空间 |
| **compacted_2b** | 约 2 字节（大 pcluster 时 4 字节） | 省空间 | 解码复杂 |
| **compacted_1** | 更紧凑 | 最省 | 只支持小 pcluster |

标志：`Z_EROFS_ADVISE_COMPACTED_2B`（`erofs_fs.h`）。
读取函数：`z_erofs_load_full_lcluster`（`zmap.c`）与
`z_erofs_load_compact_lcluster`（`zmap.c`）。

#### 两类索引项

每个索引项有一个类型字段（`advise` 的低位，掩码 `Z_EROFS_LI_LCLUSTER_TYPE_MASK`，
`erofs_fs.h`）：

```c
/* z_erofs_load_full_lcluster，zmap.c */
advise = le16_to_cpu(di->di_advise);
m->type = advise & Z_EROFS_LI_LCLUSTER_TYPE_MASK;      /* :41 取类型 */
if (m->type == Z_EROFS_LCLUSTER_TYPE_NONHEAD) {        /* :42 */
        /* NONHEAD：不记地址，只记"距离头多远" */
        m->clusterofs = 1 << vi->z_lclusterbits;
        m->delta[0] = le16_to_cpu(di->di_u.delta[0]);
        ...
        m->delta[1] = le16_to_cpu(di->di_u.delta[1]);
} else {                                                /* :55 */
        /* HEAD：记真正的物理地址 */
        m->partialref = !!(advise & Z_EROFS_LI_PARTIAL_REF);   /* :56 */
        m->clusterofs = le16_to_cpu(di->di_clusterofs);        /* :57 */
        if (advise & Z_EROFS_LI_HOLE) {                        /* :58 */
                m->compressedblks = 0;
                m->pblk = EROFS_NULL_ADDR;                     /* 空洞 */
        } else {
                m->pblk = le32_to_cpu(di->di_u.blkaddr);       /* :62 物理块号 */
        }
}
```

- **HEAD**：pcluster 的第一个 lcluster。记录真实的物理块地址。
  - 子类型：`PLAIN`（普通）、`HEAD2`（用第二种压缩算法）
  - 标志位：`PARTIAL_REF`（部分引用，去重产生，阶段 6）、`HOLE`（空洞）
- **NONHEAD**：被同一个 pcluster 覆盖的后续 lcluster。
  **不记物理地址**，只记 `delta[0]` / `delta[1]`（距离头多远）。

> **这就是"一对多"关系在磁盘上的表达**：
> 一个 pcluster 只需要一份物理地址，后续 lcluster 用 NONHEAD 占位。


## 4.4 映射主流程：`z_erofs_map_blocks_fo()`

入口是 `z_erofs_map_blocks_iter()`（`zmap.c`）：

```c
int z_erofs_map_blocks_iter(struct inode *inode, struct erofs_map_blocks *map,
                            int flags)
{
        ...
        if (map->m_la >= inode->i_size) {              /* :763 超出文件末尾 */
                ...
        } else {
                err = z_erofs_fill_inode(inode, map);   /* :768 首次访问时填元数据 */
                if (!err) {
                        if (vi->datalayout == EROFS_INODE_COMPRESSED_FULL &&
                            (vi->z_advise & Z_EROFS_ADVISE_EXTENTS))
                                err = z_erofs_map_blocks_ext(inode, map, flags);  /* :772 */
                        else
                                err = z_erofs_map_blocks_fo(inode, map, flags);   /* :774 */
                }
                if (!err)
                        err = z_erofs_map_sanity_check(inode, map);   /* :777 */
        }
}
```

两条分支：

- `z_erofs_map_blocks_ext()`（`zmap.c`）：extents 格式（较新的格式）
- `z_erofs_map_blocks_fo()`（`zmap.c`）：lcluster 索引格式（经典格式）

本章讲后者，它更能体现"索引查找"的本质。

#### 第一步：算逻辑簇号

```c
/* zmap.c, :423-424 */
ofs = flags & EROFS_GET_BLOCKS_FINDTAIL ? inode->i_size - 1 : map->m_la;
...
initial_lcn = ofs >> lclusterbits;                    /* :423 逻辑簇号 */
endoff = ofs & ((1 << lclusterbits) - 1);             /* :424 簇内偏移 */
```

这一步和阶段 3 的"算块号"一样是算术——
但注意，算出来的是**逻辑簇号**，还不是物理地址。

#### 第二步：从磁盘读索引项

```c
/* zmap.c */
err = z_erofs_load_lcluster_from_disk(&m, initial_lcn, false);
```

这个函数内部按格式分派到 full / compact 的读取函数。

#### 第三步：判断是不是 HEAD（关键分支）

```c
/* zmap.c */
if (m.type != Z_EROFS_LCLUSTER_TYPE_NONHEAD && endoff >= m.clusterofs) {
        /* 情况 A：这个 lcluster 就是某个 pcluster 的头 */
        m.headtype = m.type;
        map->m_la = (m.lcn << lclusterbits) | m.clusterofs;    /* :437 */
        ...
} else {
        /* 情况 B：不是头，要往回找它所属 pcluster 的头 */
        if (m.type != Z_EROFS_LCLUSTER_TYPE_NONHEAD) {
                end = (m.lcn << lclusterbits) | m.clusterofs;
                map->m_flags &= ~EROFS_MAP_PARTIAL_MAPPED;
                m.delta[0] = 1;
        }
        err = z_erofs_extent_lookback(&m, m.delta[0]);          /* :452 往回找 */
        ...
}
```

**情况 B 是理解压缩映射的关键**：

你可能落在某个 pcluster 中间的某个 lcluster 上。
此时索引项（NONHEAD）里没有物理地址，
必须通过 `z_erofs_extent_lookback()`（`zmap.c`）**往回走** `delta[0]` 步，找到头。

> 类比：你站在一列火车的第 3 节车厢，想知道车头在哪。
> 车厢里没写车头位置（NONHEAD 不记地址），
> 但写了"距车头 2 节"（delta），于是往前走 2 节就找到了。

#### 第四步：得到物理地址

```c
/* zmap.c */
map->m_pa = erofs_pos(sb, m.pblk);
```

`m.pblk` 是**块号**，经 `erofs_pos()` 转成**字节地址**。

**记住：`m_pa` 是字节地址，不是块号。**

而且（与阶段 3 的 flat 路径不同）**它不保证块对齐**——
因为 pcluster 是连续存放的，第二个 pcluster 的起点取决于前一个有多长。

#### 第五步：选择压缩算法格式

```c
/* zmap.c */
if (m.headtype == Z_EROFS_LCLUSTER_TYPE_PLAIN) {
        if (vi->z_advise & Z_EROFS_ADVISE_INTERLACED_PCLUSTER)
                map->m_algorithmformat = Z_EROFS_COMPRESSION_INTERLACED;
        else
                map->m_algorithmformat = Z_EROFS_COMPRESSION_SHIFTED;
} else if (m.headtype == Z_EROFS_LCLUSTER_TYPE_HEAD2) {
        map->m_algorithmformat = vi->z_algorithmtype[1];
} else {
        map->m_algorithmformat = vi->z_algorithmtype[0];
}
```

`SHIFTED` 与 `INTERLACED` 是 LZ4 的两种数据排布方式，
区别是压缩数据在页里的摆放顺序不同（阶段 5 会看到它影响解压）。

#### 收尾：注意是 `unmap` 不是 `put`

```c
/* zmap.c */
erofs_unmap_metabuf(&m.map->buf);
```

**这是有意为之**（本项目专门核查过）：

`erofs_unmap_metabuf()` 只解除内核映射，**不释放** folio 引用。  
因为这个 folio 很快还会被用到——下一个 lcluster 的索引很可能就
在 `ALIGN(end, 8) + 16` 处（仅隔 16 字节），
不释放就能命中 `erofs_bread` 的复用快路径（`data.c`），省一次元数据 IO。

> ⚠️ **千万不要"顺手"把它改成 `erofs_put_metabuf()`。**
> 那会引入性能回退。正确做法是加注释说明意图。
> （这是本项目核查后给出的结论。）

#### 一个值得对照的细节

`zmap.c`：

```c
if (fragment && vi->datalayout == EROFS_INODE_COMPRESSED_FULL)
        vi->z_fragmentoff |= (u64)m.pblk << 32;
```

看起来像"把块号当字节用的 bug"，**其实不是**——
`m.pblk` 这个槽位被 mkfs **复用**了，存的是 `fragmentoff` 的**高 32 位**
（低 32 位来自 `h_fragmentoff`），合起来才是完整的 64 位偏移。
本项目核查后确认这是**有意的位打包**。

> 这个例子说明：**在 EROFS 里看到"不合理"的位运算，先怀疑自己没理解字段复用，
> 而不是急着报 bug。** 反过来也说明，这类复用值得加注释。


## 4.5 ⭐ pcluster 状态机

![pcluster 状态机](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-09-erofs-4-11-pcluster-state-machine.svg)

**这一节回答一个核心问题：同一个 pcluster 被多个并发读请求需要时，怎么避免重复解压？**

#### 先看问题

场景：10 个进程同时读同一个压缩文件的前 4KB。

```
没有协调：各读各的、各解各的 → 同一份数据解压 10 次 → CPU 浪费 9 倍
有协调  ：第一个解压，其余 9 个等结果
```

这就是 pcluster 必须是一个**有状态对象**的原因。

#### 三种状态

定义在 `zdata.c`：

```c
enum z_erofs_pclustermode {
        /* 已被链接到另一个处理链 */
        Z_EROFS_PCLUSTER_INFLIGHT,                    /* :479 */
        /*
         * 弱化的 FOLLOWED：可能因 uptodated managed folios
         * 被分派到旁路队列，所以相关 folio 不能用于 in-place IO
         * （pcluster 可能在另一个队列里乱序解码）
         */
        Z_EROFS_PCLUSTER_FOLLOWED_NOINPLACE,          /* :487 */
        /* 刚链接到当前处理链，相关 folio 可用于 in-place IO */
        Z_EROFS_PCLUSTER_FOLLOWED,                    /* :493 */
};
```

**注意枚举顺序是有意义的**：`INFLIGHT(0) < NOINPLACE(1) < FOLLOWED(2)`，
所以判据可以写成一个比较（`zdata.c`）：

```c
if (fe->mode < Z_EROFS_PCLUSTER_FOLLOWED)    /* 不能 in-place */
```

#### 核心代码

`z_erofs_pcluster_begin()`（`zdata.c`）：

```c
        /* ① 查：这个 pcluster 有人管吗？（zdata.c） */
        do {
                rcu_read_lock();
                pcl = xa_load(&EROFS_SB(sb)->managed_pslots, map->m_pa);
                needretry = pcl && !z_erofs_get_pcluster(pcl);
                rcu_read_unlock();
        } while (needretry);

        if (pcl) {
                fe->pcl = pcl;
                ret = -EEXIST;                        /* :840 已存在 */
        } else {
                ret = z_erofs_register_pcluster(fe);   /* :842 新建 */
        }

        /* ② 抢：原子地争抢"谁负责解压"（zdata.c） */
        if (ret == -EEXIST) {
                mutex_lock(&fe->pcl->lock);
                if (!cmpxchg(&fe->pcl->next, NULL, fe->head)) {
                        fe->head = fe->pcl;
                        fe->mode = Z_EROFS_PCLUSTER_FOLLOWED;   /* :851 我接管 */
                } else {
                        fe->mode = Z_EROFS_PCLUSTER_INFLIGHT;   /* :853 别人在处理 */
                }
        }
```

两个关键机制：

1. **`managed_pslots`**：一个 xarray，按 `map->m_pa`（物理地址）索引所有在处理的 pcluster。
   物理地址相同 = 同一个 pcluster，这是判重的关键。

2. **`cmpxchg(&pcl->next, NULL, fe->head)`**：原子比较并交换。
   - `next` 原本是 `NULL` → 我成功接管，返回旧值 NULL → `FOLLOWED`
   - `next` 已被别人设置 → 我失败 → `INFLIGHT`（别人在解压，我等结果）

**这是典型的无锁并发模式**：用一个原子操作决定"谁是负责人"。

#### 后续流程

```
pcluster_begin（决定状态）
    ↓
读压缩数据（提交 bio）
    ↓
z_erofs_endio()          zdata.c   ← IO 完成回调
    ↓
z_erofs_decompress_queue()  zdata.c   ← 排队
    ↓
z_erofs_decompress_pcluster()  zdata.c   ← 真正解压
    ↓
z_erofs_pcluster_end()   zdata.c    ← 释放、唤醒等待者
```

**META 特例**：如果 `m_flags` 有 `META`（ztailpacking 内联数据），
不走 pcluster 机制，直接用 `erofs_bread` 读（`zdata.c`）。


## 4.6 in-place 解压 vs cached 解压

![in-place vs cached](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-09-erofs-12-inplace-vs-cached.svg)

解压需要一块**目标内存**放结果。这块内存从哪来？

| | in-place | cached |
|---|---|---|
| 目标内存 | **文件自己的** page cache 页 | EROFS 自管的临时页 |
| 额外拷贝 | 无 | 多一次 |
| 结果缓存 | 不缓存（下次读还要解压） | 留在 managed cache，可复用 |
| 约束 | 尾部需要 margin | 无 |
| 触发条件 | `mode == FOLLOWED` 且 folio 可用 | 其余情况 |

managed cache 是一个专用于此的假 inode（`internal.h` 的 `managed_cache`，
通过 `MNGD_MAPPING(sbi)` 访问，定义在 `internal.h`）。

#### 为什么 in-place 需要 margin？

这是本节最需要理解的一点。

LZ4 这类算法解压时会**向前回看**已解压的数据（LZ4 回看窗口最大 64KB）。
如果目标内存就是源数据所在的那一页，就会出问题：

```
目标页（同时也是源数据所在）：
  ┌────────────┬──────────────┐
  │ 已解压覆盖  │  还未覆盖     │
  │            │ （源数据在这）│
  └────────────┴──────────────┘
                ↑            ↑
             读指针        写指针

  写指针不断前进，可能追上读指针，
  于是"回看"读到的是自己刚写进去的错误数据。
```

解决办法：**目标缓冲区尾部多留一段空间（margin）**，
保证回看窗口始终能读到未被覆盖的原始压缩数据。

这个 margin 的大小由解压算法决定，
LZ4 对应 `LZ4_DECOMPRESS_INPLACE_MARGIN` 等常量（阶段 5 详讲）。

> in-place 解压是 EROFS 最早宣传的核心特性之一
> （2019 年第一份官方演讲就专门有一页讲 "Decompression In-place"）。
> 它的价值是**省一次内存拷贝**——在手机这种内存带宽紧张的设备上很关键。


## 4.7 常见误解

**误解一：以为一个 lcluster 对应一个 pcluster**

不是。一个 pcluster 解压后可能覆盖多个 lcluster（4.2 节）。
所以才有 HEAD / NONHEAD 的区分，才有 `extent_lookback` 往回找。

**误解二：以为 `m_pa` 是块号**

不是，是**字节地址**（`zmap.c` 用 `erofs_pos()` 转过）。
而且**不保证块对齐**——pcluster 连续存放，起点取决于前面有多长。

这个不对齐正是 `pageofs_in` 存在的原因，也是解压路径复杂的一个来源。

**误解三：看到 `m.pblk << 32` 就以为是 bug**

`zmap.c` 的这行是有意的位打包（4.4 节末尾讲过）。
在 EROFS 里遇到奇怪的位运算，先查 mkfs 侧这个字段是怎么写的。

**误解四：以为 `erofs_unmap_metabuf` 是漏了 put**

不是。`zmap.c` 特意只 unmap 不 put，为的是让下一个索引项命中复用快路径。
（但这也意味着调用方要清楚后续谁负责 put —— 又是一处人工契约。）

**误解五：以为压缩文件读一次只解压一次**

不一定。如果同一次读涉及多个 pcluster，每个 pcluster 都要单独解压。
反过来，多个 pcluster 也可能被合并成一次批量提交。

## 术语速查

| 术语 | 含义 | 出处 |
|---|---|---|
| lcluster | 逻辑簇，压缩前的固定长度块 | 4.2 |
| pcluster | 物理簇，一次解压的物理单位 | 4.2 |
| HEAD / NONHEAD | 索引项类型：pcluster 的头 / 被覆盖的后续簇 | `zmap.c` |
| `delta[0]`/`delta[1]` | NONHEAD 记录"距头多远" | `zmap.c` |
| `extent_lookback` | 从 NONHEAD 往回找 HEAD | `zmap.c` |
| `managed_pslots` | 按物理地址索引在处理的 pcluster（xarray） | `zdata.c` |
| `cmpxchg` | 原子争抢"谁负责解压" | `zdata.c` |
| FOLLOWED / INFLIGHT | 我接管 / 别人在处理 | `zdata.c` |
| managed cache | EROFS 自管的临时页（cached 解压用） | `internal.h` |
| margin | in-place 解压时在目标尾部留的安全余量 | 4.6 |
| SHIFTED / INTERLACED | LZ4 的两种数据排布 | `zmap.c` |


## 自测检查点

1. 为什么压缩文件不能像非压缩那样用算术定位？
2. lcluster 和 pcluster 的区别？为什么一个 pcluster 能覆盖多个 lcluster？
3. 索引项分 HEAD 和 NONHEAD，NONHEAD 为什么不记物理地址？
4. 如果你要读的 lcluster 是 NONHEAD，代码怎么找到物理地址？
5. `zmap.c` 那个分支判断在判断什么？`endoff >= m.clusterofs` 意味着什么？
6. pcluster 为什么必须有状态？没有状态机会发生什么？
7. `cmpxchg(&pcl->next, NULL, fe->head)` 成功和失败分别意味着什么？
8. 三种状态的枚举顺序为什么是有意的？
9. in-place 解压为什么需要 margin？具体是什么风险？
10. `m_pa` 是块号还是字节地址？它保证块对齐吗？为什么？
11. `zmap.c` 为什么用 `erofs_unmap_metabuf` 而不是 `erofs_put_metabuf`？
12. 看到 `zmap.c` 的 `(u64)m.pblk << 32`，你的第一反应应该是什么？

## 自测答案

<details>
<summary>点击展开答案</summary>

**1. 为什么不能算术定位？**

压缩后长度**不定**，逻辑偏移与物理位置之间没有固定比例。
阶段 1 实测：400000 字节可压到 4096 字节（1.02%），
也可能随机数据压不动（100%）。所以只能查索引表。

**2. lcluster 与 pcluster？**

- **lcluster**：压缩**前**的固定长度块（通常 4K 的倍数）
- **pcluster**：一次解压的**物理单位**，压缩后多长就是多长

一个 pcluster 解压后得到的数据可能跨越多个 lcluster——
因为压缩是以"一大块"为单位做的，而逻辑视图是等分的。

**3. NONHEAD 为什么不记物理地址？**

因为同一个 pcluster 覆盖的所有 lcluster
共享**同一份**物理地址（都在那个 pcluster 里）。
只在 HEAD 记一次，后续用 NONHEAD 占位，
靠 `delta` 表达"距头多远"，可以省下大量索引空间。

**4. NONHEAD 怎么找到物理地址？**

调 `z_erofs_extent_lookback()`（`zmap.c`）
**往回走** `delta[0]` 步，找到对应的 HEAD，再从 HEAD 取物理地址。

（类比：站在第 3 节车厢，看"距车头 2 节"，往前走 2 节。）

**5. `zmap.c` 在判断什么？**

```c
if (m.type != Z_EROFS_LCLUSTER_TYPE_NONHEAD && endoff >= m.clusterofs)
```

判断"**当前这个 lcluster 是不是就是某个 pcluster 的头**"：

- `m.type != NONHEAD`：它至少是个 HEAD 候选
- `endoff >= m.clusterofs`：要读的偏移不早于这个头覆盖的范围起点

两者都成立 → 情况 A，直接用这个头的信息。
否则 → 情况 B，要往回找（`extent_lookback`）。

**6. pcluster 为什么必须有状态？**

因为同一个 pcluster 可能被**多个并发读请求**同时需要。
没有状态就无法判断"是不是有人在解压了"，
结果就是每个请求各解各的，同一份数据重复解压，浪费 CPU。

状态还决定了能不能用 in-place（见第 8 题）。

**7. cmpxchg 成功/失败的含义？**

- **成功**（`next` 原本是 NULL）→ 我是第一个接管者，
  `mode = FOLLOWED`，**由我负责解压**。
- **失败**（`next` 已被设置）→ 别人先接管了，
  `mode = INFLIGHT`，我挂到它的链上**等结果**，不重复解压。

**8. 枚举顺序为什么有意为之？**

因为顺序表达了"能力递增"：
`INFLIGHT(0) < FOLLOWED_NOINPLACE(1) < FOLLOWED(2)`。

于是"能不能 in-place"可以写成一次比较（`zdata.c`）：

```c
if (fe->mode < Z_EROFS_PCLUSTER_FOLLOWED)   /* 不能 in-place */
```

这是内核里常见的"用枚举顺序编码能力层级"的手法。

**9. in-place 为什么需要 margin？**

风险是**写指针追上读指针**：

LZ4 解压时会向前回看已解压数据（窗口最大 64KB）。
如果目标内存就是源数据所在的页，解压写入会逐步覆盖源数据。
当写入追上回看位置时，解压器读到的就是**自己刚写进去的错误数据**，
而不是原始压缩数据——解压结果错误。

margin 就是在目标缓冲区尾部多留一段空间，
保证回看窗口始终落在未被覆盖的原始压缩数据上。

**10. `m_pa` 是块号还是字节地址？保证对齐吗？**

是**字节地址**（`zmap.c` 用 `erofs_pos()` 从块号转来）。

**不保证块对齐**。因为 pcluster 是连续紧凑存放的，
第二个 pcluster 的起点取决于第一个压缩后有多长——
几乎不可能刚好落在块边界上。

这个不对齐是 `pageofs_in` 存在的原因，
也是解压路径比非压缩路径复杂的重要原因。

**11. 为什么用 unmap 而不是 put？**

**有意为之的性能优化**。

`erofs_unmap_metabuf()` 只解除内核映射，不释放 folio 引用。
因为下一个 lcluster 的索引很可能就在附近
（`ALIGN(end, 8) + 16`，仅隔 16 字节），
保留引用就能命中 `erofs_bread` 的复用快路径（`data.c`），省一次元数据 IO。

⚠️ 不要"顺手修正"成 `put`——那是性能回退。
本项目核查后的建议是**加注释说明意图**。

**12. 看到 `(u64)m.pblk << 32` 的第一反应？**

**先怀疑字段被复用了，而不是急着报 bug。**

这一行（`zmap.c`）里 `m.pblk` 存的其实是 `fragmentoff` 的**高 32 位**，
低 32 位来自 `h_fragmentoff`，合起来才是完整的 64 位偏移。
mkfs 侧（`erofs-utils/lib/compress.c`）复用了这个原本存块地址的槽位。

本项目核查后确认：**不是 bug，是有意的位打包**。

> 通用方法论：在 EROFS 里遇到"不合理"的位运算，
> 先去 mkfs 侧查这个字段是怎么写进去的。

</details>

## 与后续阶段的关系

- **阶段 5**：解压后端。本章只讲了"决定解压"，
  阶段 5 讲"解压本身"（四种算法、同步异步、硬件加速）
- **阶段 6**：fragment / ztailpacking 详解、去重（partial-ref 的来源）

## 参考
[linux-7.2](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)
