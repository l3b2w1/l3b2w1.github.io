---
layout:     post
title:      EROFS dedupe
subtitle:   EROFS 去重
date:       2026-09-22
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 15 · 特性专题：rolling-hash 去重（dedupe）

> 特性标志：`EROFS_FEATURE_INCOMPAT_DEDUPE`（`internal.h`）
> 内核侧代码：很少——主要在 `decompressor.c`（处理 deduped 页）与 sysfs 暴露
> **重要**：本特性**以 mkfs 侧为主**，内核只负责"认得它 + 正确处理去重页"
>
> 本文回答：**为什么压缩之后还要去重** → **rolling hash 怎么找到重复块** →
> **内核这边的少量工作是什么** → **`fillgaps` 为什么关键** →
> **与 fragment 的区别**（06 专题点名最容易混淆）。

## 本专题目标（读完你应该能做到什么）

1. 说清去重解决什么问题，以及**为什么压缩之后仍需要去重**
2. 解释 **rolling hash（滚动哈希）** 的基本思路（不要求懂算法细节）
3. 说明 ⚠️ **内核侧几乎不做去重**——重头戏在 mkfs
4. 解释 **`fillgaps`** 字段为什么是内核侧的关键（并联系 D12 缺陷）
5. **清楚区分 dedupe 与 fragment**（最容易混淆的一对）
6. 知道怎么确认一个镜像启用了 dedupe

## 图解

![dedupe（rolling hash）：跨文件重复只存一份，内核只需认得它](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-22-erofs-34-dedupe-rolling-hash.svg)

**一句话**：mkfs 用 rolling hash 找出跨文件的相同块、**只存一份**，其余位置标成"引用"；
内核**不算哈希**，只需认得这种 pcluster（**partial-referenced**）并正确解压。

自上而下五段 + 底部澄清：

| 段 | 回答什么 | 一句话 |
|---|---|---|
| **① mkfs**（橙） | 重复怎么被消掉 | 文件 A / B 的四个块完全相同，压缩各管各的发现不了；rolling hash 滑动窗口扫描 → 只存一份，B 记为引用 |
| **② on-disk**（黄） | 镜像里怎么标 | `Z_EROFS_LI_PARTIAL_REF`（lcluster index 的 advise 位）/ `Z_EROFS_EXTENT_PLEN_PARTIAL`（extents 形态）；superblock 打 `INCOMPAT_DEDUPE` |
| **③ 映射**（绿） | 内核怎么认 | `m->partialref` → `map->m_flags |= EROFS_MAP_PARTIAL_REF` |
| **④ 传递**（蓝） | 怎么带到解压 | `pcl->partial` → `.partial_decoding`；另有 `.fillgaps = be->keepxcpy`（★ D12） |
| **⑤ 解压**（紫） | 解压时做什么 | `partial_decoding` 决定只解压一部分；`fillgaps` 决定空隙槽（未被整页认领的输出槽）是否分配临时页作为解压落点 / 后续拷贝源 |

**⚠️ 底部红框的三件事**（都比想象中容易搞混）：

1. **一个机制三个名字** —— rolling hash = variant-CDC = 内核的
   **partial-referenced pcluster**，是同一件事换了三种说法。
2. **dedupe ≠ fragment** —— 前者消**跨文件**相同块，后者收**压缩零头**；
   两者在 mkfs 侧是两个独立开关（`-Ededupe` / `-Efragdedupe`）。
3. **位别名（冷知识）** —— `EROFS_FEATURE_INCOMPAT_DEDUPE` 与
   `EROFS_FEATURE_INCOMPAT_FRAGMENTS` **都是 `0x00000020`**，
   所以开了 dedupe 的镜像，`erofs_sb_has_fragments()` 同样为真
   ⇒ 挂载时也会去 igot packed inode（即使这份镜像其实没有 fragment）。

## 一、特性缘由：压缩之后为什么还要去重

#### 1.1 压缩解决不了的重复

压缩（LZ4/LZMA 等）消除的是**单个文件内部**的冗余。
但下面这种重复它管不了：

```
文件 A： [块1][块2][块3][块4]
文件 B： [块1][块2][块3][块4]     ← 与 A 完全相同的四个块
```

压缩算法各自处理各自的文件，
**不会**发现"文件 B 的内容其实和文件 A 一样"。

⇒ 磁盘上存了两份。

#### 1.2 场景：容器镜像里大量重复

容器镜像中这种"跨文件重复"极其常见：

- 多个镜像基于同一个基础层
- 不同路径下的相同库文件
- 升级前后只改了一点的大文件

⇒ 去重能省下**相当可观**的磁盘空间。

#### 1.3 怎么做：找出相同的数据块

思路很朴素：

> 把每个 pcluster 的内容算个哈希，
> 哈希相同的就只存一份。

难点在于**效率**：如果按固定边界切块，
插入/删除一点内容就会让后面所有块的边界错位，去重率暴跌。

⇒ 这就是 **rolling hash（滚动哈希）** 的用武之地——
它能在**任意位置**高效地计算滑动窗口的哈希，
从而找到"内容相同但位置不同"的块。

## 二、设计理念

#### 理念 1：把去重放在 mkfs，不在内核

这是理解本特性的**关键**：

| | 谁做 |
|---|---|
| 算哈希、找重复、决定只存一份 | **mkfs（用户态工具）** |
| 识别该特性、正确读取去重后的数据 | **内核** |

**为什么？**

- 去重需要全局扫描与大量计算——**构建时做一次**远比运行时做划算
- 内核是只读的，运行时去重既无必要也太慢

⇒ 内核侧的代码量很小。看到 `INCOMPAT_DEDUPE` 这个 feature flag
基本就代表了内核的"认知"程度。

#### 理念 2：用 incompat 标志保护

```c
EROFS_FEATURE_FUNCS(dedupe, incompat, INCOMPAT_DEDUPE)
```

`incompat` 意味着：**不认识这个特性的内核不能挂载该镜像**。

原因很直接——去重改变了数据的组织方式，
老内核按常规方式读会读到错的东西。宁可拒绝挂载。

#### 理念 3：去重页 —— 给未认领的输出槽补一个临时页

解压时，如果某个输出槽**没有预先认领的目标页**（`decompressed_pages[i] == NULL`），
内核需要知道**怎么处理它**。

这就是 `fillgaps` 的作用（见下）。

## 三、实现架构

#### 3.1 内核侧：不算哈希，但要认得「partial-referenced pcluster」

内核里**没有** rolling hash 的实现。它实际做的是**四步**：

```
① 挂载时：识别 INCOMPAT_DEDUPE 特性
      └ 不认识 → 拒绝挂载（incompat 语义）（见宏定义 EROFS_ALL_FEATURE_INCOMPAT）

② 映射时（zmap.c）：从磁盘标志位认出"这段是引用"
      └ m->partialref = !!(advise & Z_EROFS_LI_PARTIAL_REF)
      └ if (m.partialref)  map->m_flags |= EROFS_MAP_PARTIAL_REF
        （extents 形态则看 Z_EROFS_EXTENT_PLEN_PARTIAL）

③ 组装解压请求（zdata.c）：把这个事实带下去
      └ .partial_decoding = pcl->partial
      └ .fillgaps         = be->keepxcpy      ← ★ D12 缺陷点

④ 解压时（decompressor.c）：两个开关各管一件事
      └ if (rq->partial_decoding)   → 只解压其中一部分（还影响能否 in-place）
      └ if (!*pgo && rq->fillgaps)  → 空隙槽：分配一页作为解压落点（不置零）
```

**这是两条并行的线索，别混成一条**：

| 开关 | 来自 | 管什么 |
|---|---|---|
| `partial_decoding` | `pcl->partial`（源自 on-disk 的 PARTIAL_REF 标志） | 这个 pcluster 只含**部分**解压后的数据 |
| `fillgaps` | `be->keepxcpy`（栈上变量） | 输出里的**空隙槽**（未被整页认领）要不要分配临时页 |

⇒ 全程**没有**哈希计算、没有重复查找——找重复全是 mkfs 的活。
内核的贡献是"认得它 + 把它解对"。

#### 3.2 关键：`fillgaps` 字段

`struct z_erofs_decompress_req`（`compress.h`）里的 `fillgaps`：

```c
bool inplace_io, partial_decoding, fillgaps;
```

含义：**输出里有"空隙"（gap，即未被整页认领的输出槽）时，是否分配一个临时页接住解压输出**。

- `fillgaps = true` → 为该槽**分配一个临时页**（`erofs_allocpage()` → `alloc_page()`，**不带 `__GFP_ZERO`，不会置零**）
- `fillgaps = false` → 跳过，不分配

⇒ 如果 `fillgaps` 传错，deduped 页可能**没有正确初始化**，
读到错误数据。

> ⚠️ **`fillgaps` 不是 dedupe 专用**：`decompressor_deflate.c` 与
> `decompressor_zstd.c` 里都会无条件写 `rq->fillgaps = true`
> （注释原文："DEFLATE/ZSTD doesn't support NULL output buffer"）。
> 所以「`fillgaps` 为真」**不能**反推「这一页是 deduped 页」。

> 📌 **这与 D12 缺陷直接相关**：
> `z_erofs_decompress_queue()` 里 `be.keepxcpy` 未初始化，
> 而它被当作 `rq.fillgaps` 传下去（`fillgaps = be->keepxcpy`）——
> 栈上的垃圾值会导致 deduped 页处理错误。

#### 3.3 sysfs 暴露

```c
EROFS_ATTR_FEATURE(dedupe);
```

挂载后可通过 `/sys/fs/erofs/<dev>/features` 看到该特性是否启用。

## 四、关键结构体与字段

#### 4.1 `struct z_erofs_decompress_req`（`compress.h`）

本特性唯一直接相关的字段就是 **`fillgaps`**。

| 字段 | 与 dedupe 的关系 |
|---|---|
| `fillgaps` | **核心**。决定空隙槽是否分配临时页作为解压落点 / 后续拷贝源 |
| `out[]` / `outpages` | 输出页数组，deduped 页在其中 |
| `alg` | 压缩算法（去重与算法无关） |

#### 4.2 feature 标志（`internal.h`）

```c
EROFS_FEATURE_FUNCS(dedupe, incompat, INCOMPAT_DEDUPE)
```

展开出 `erofs_sb_has_dedupe(sbi)` 之类的辅助函数。

#### 4.3 `erofs_sb_info`

```c
u32 feature_incompat;      /* INCOMPAT_DEDUPE 位在这里 */
```

## 五、主要函数

内核侧确实**没有**"dedupe 专属的算法函数"（没有 rolling hash、没有查重），  
但"**认标志位 → 打标记 → 带进解压请求 → 决定怎么解压**"这条链路是实打实存在的：

| 环节 | 位置 | 做什么 |
|---|---|---|
| ① 认标志位 | `zmap.c` | 从 lcluster index / extent 读出「这个 pcluster 只含部分数据」 |
| ② 打标记 | `zdata.c` | 记到 `pcl->partial` |
| ③ 带进请求 | `zdata.c` | `.partial_decoding = pcl->partial`、`.fillgaps = be->keepxcpy` |
| ④ 决定怎么解压 | `decompressor.c` | 部分解压 or 全量解压；空隙页要不要补 |

#### 5.1 `zmap.c`：认出「这段是引用」

去重的产物落到 on-disk 上就是一个**标志位**。两种 inode 形态各有一处读法。

**noncompact 形态** —— `z_erofs_load_lcluster_from_disk()` 从 lcluster index 的 `advise` 位取：

```c
} else {
        m->partialref = !!(advise & Z_EROFS_LI_PARTIAL_REF);
        m->clusterofs = le16_to_cpu(di->di_clusterofs);
        ...
```

`Z_EROFS_LI_PARTIAL_REF` 是 `1 << 15`（`erofs_fs.h`），注释很直白：
*this pcluster refers to partial decompressed data*。

随后在 `z_erofs_map_blocks_fo()` 末尾转成内核的映射标志：

```c
if (m.partialref)
        map->m_flags |= EROFS_MAP_PARTIAL_REF;
```

**extents 形态**则把同一信息放在 `m_plen` 的高位（`Z_EROFS_EXTENT_PLEN_PARTIAL`，`BIT(27)`）：

```c
if (map->m_plen & Z_EROFS_EXTENT_PLEN_PARTIAL)
        map->m_flags |= EROFS_MAP_PARTIAL_REF;
map->m_plen &= Z_EROFS_EXTENT_PLEN_MASK;
```

⇒ 两条路最终都落到 `EROFS_MAP_PARTIAL_REF`（`0x0008`），后面就统一了。

配套的判据在 `internal.h`：

```c
#define EROFS_MAP_FULL(f)  (!((f) & (EROFS_MAP_PARTIAL_MAPPED | \
                              EROFS_MAP_PARTIAL_REF)))
```

即：**既不是「部分映射」也不是「部分引用」，才算一张完整的映射**。这个宏在 5.2 里很关键。

#### 5.2 `zdata.c`：`pcl->partial` 什么时候为真

理解它的关键是：**默认值为真**。三处赋值：

**① 新建 pcluster 时直接置 `true`**：

```c
lockref_init(&pcl->lockref);
pcl->algorithmformat = map->m_algorithmformat;
pcl->pclustersize = map->m_plen;
pcl->length = 0;
pcl->partial = true;
```

**② 只有映射完整、且收齐的长度正好等于 `m_llen` 时，才改回 `false`**（`z_erofs_scan_folio()`）：

```c
if (EROFS_MAP_FULL(map->m_flags) &&
    f->pcl->length == map->m_llen)
        f->pcl->partial = false;
```

**③ pcluster 用完后重置，又回到 `true`**：

```c
pcl->length = 0;
pcl->partial = true;
pcl->besteffort = false;
```

⇒ **去重产生的 pcluster 永远走不到第 ② 步**——它带着 `EROFS_MAP_PARTIAL_REF`，
`EROFS_MAP_FULL()` 恒为假，于是 `partial` 保持真。  
这就是"只解压一部分"这个开关的来源。

#### 5.3 `zdata.c`：把两个开关塞进解压请求

`z_erofs_decompress_queue()` 组装 `z_erofs_decompress_req` 时：

```c
.in = be->compressed_pages,
.out = be->decompressed_pages,
...
.inplace_io = overlapped,
.partial_decoding = pcl->partial,
.fillgaps = be->keepxcpy,
.gfp = pcl->besteffort ? GFP_KERNEL : GFP_NOWAIT | __GFP_NORETRY
```

⚠️ 这两个开关的**来源完全不同**，别混为一谈：

| 开关 | 来源 | 性质 |
|---|---|---|
| `partial_decoding` | `pcl->partial` ← 镜像里的标志位 | 客观事实 |
| `fillgaps` | `be->keepxcpy` ← **栈上的局部变量** | 运行时状态 |

后者正是 **D12 缺陷**：`be.keepxcpy` 未经初始化就被当作 `rq.fillgaps` 传下去，
栈上的垃圾值会让"空隙页该不该补"变成随机行为。

#### 5.4 `decompressor.c`：`partial_decoding` 决定怎么解压

以 LZ4 为例（`z_erofs_lz4_decompress()`），这是本专题最落地的一处：

```c
out = dst + rq->pageofs_out;
if (rq->partial_decoding)
        ret = LZ4_decompress_safe_partial(src + inputmargin, out,
                        rq->inputsize, rq->outputsize, rq->outputsize);
else
        ret = LZ4_decompress_safe(src + inputmargin, out,
                                  rq->inputsize, rq->outputsize);
```

- 普通压缩：整段解压（`LZ4_decompress_safe`）
- 去重产生的 partial pcluster：**只解出需要的那一截**
  （`_partial` 版本，最后那个参数就是要的长度）
- LZMA 同样有对应分支（`decompressor_lzma.c` 里 `!rq->partial_decoding`）

它还影响能否 in-place（就地解压）：

```c
if (!rq->partial_decoding && may_inplace &&
    omargin >= LZ4_DECOMPRESS_INPLACE_MARGIN(rq->inputsize)) {
```

⇒ 部分解压时不做 in-place —— 输出缓冲区的布局不满足就地解压的前提。

#### 5.5 `fillgaps`：输出里的「空隙」怎么办

解压输出是一组页指针 `rq->out[]`。去重时某些槽位的内容与别处相同、
不需要重新产生，这些槽位可能是 `NULL`。  
`decompressor.c` 里这样处理：

```c
pgo = &rq->out[dctx->no];
if (!*pgo && rq->fillgaps) {            /* deduped */
        *pgo = erofs_allocpage(pgpl, rq->gfp);
        if (!*pgo) {
                dctx->kout = NULL;
                return ERR_PTR(-ENOMEM);
        }
        set_page_private(*pgo, Z_EROFS_SHORTLIVED_PAGE);
}
```

- `fillgaps = true` → 给这些空槽分配一页（内容为零），解压器有地方可写
- `fillgaps = false` → 跳过，不分配

⚠️ **它不是 dedupe 专用**。DEFLATE / ZSTD 后端会无条件打开：

```c
rq->fillgaps = true;    /* 后端不支持 NULL 输出缓冲（DEFLATE） */
rq->fillgaps = true;    /* 后端不支持 NULL 输出缓冲（ZSTD） */
```

所以**不能**由 `fillgaps == true` 反推"这一页是 deduped 页"。

#### 5.6 两个「名不副实」的入口

| 位置 | 说明 |
|---|---|
| `erofs_sb_has_dedupe()` | 由 `internal.h` 的 `EROFS_FEATURE_FUNCS(dedupe, ...)` 宏生成，  但 **`fs/erofs/` 里没有任何调用点** —— 内核判断某段数据是否去重，靠的是 lcluster index 的 advise 位 / extent 的 m_plen 高位 的标志位，不是这个 superblock 特性位 |
| `EROFS_ATTR_FEATURE(dedupe)` | 只把 `dedupe` 这个名字暴露到 sysfs（`/sys/fs/erofs/<dev>/features`），方便运维确认 |

⇒ 这也解释了 15 专题为什么说"内核侧代码量很小"：  
真正的判据散落在`zmap.c` / `zdata.c` / `decompressor.c` 的**既有路径**里，dedupe 只是借道，
没有独立的一套代码。

**mkfs 侧**（不在内核，仅说明）：负责 rolling hash 计算、
重复判定、只写一份、记录引用关系。


## 六、来龙去脉：完整串一遍

```
① 构建镜像（mkfs，用户态）
     ├ 按 rolling hash 滑动窗口扫描所有压缩数据
     ├ 发现内容相同的块 → 只保留一份
     ├ 其余位置记为"引用"（deduped）
     └ 在 superblock 打上 INCOMPAT_DEDUPE 标志
        │
② 挂载（内核）
     ├ 读 feature_incompat
     ├ 若内核不认识 INCOMPAT_DEDUPE → 拒绝挂载
     └ 认识 → 继续
        │
③ 读某个文件，需要解压
        │
④ 组装 z_erofs_decompress_req
     └ fillgaps = be->keepxcpy     ← ★ 必须为确定值
        │
⑤ 解压后端处理输出页
     ├ 正常页：解压写入
     └ deduped 页（!*pgo）：
           if (rq->fillgaps) → 分配一个临时页（不置零）
        │
⑥ 数据完整 → 读完成
```

**第 ⑤ 步是内核侧对 dedupe 的全部贡献**：
认出"这个页是去重页"，给它一个置零的页。

## 七、动手验证

#### 验证 1：确认内核侧特性定义

```bash
cd /sdd/linux/linux-stable/fs/erofs
grep -rn "dedupe\|INCOMPAT_DEDUPE" .
```

会看到：feature 定义、sysfs 暴露、以及 `decompressor.c` 里的 `fillgaps` 分支。
**注意代码量很小**——这本身就印证了"重头在 mkfs"。

#### 验证 2：确认镜像是否启用 dedupe

```bash
/opt/erofs-utils/bin/dump.erofs -s /tmp/erofs-lab/comp2.erofs
```

看 superblock 的 incompat feature 里有没有 dedupe 位。

#### 验证 3：VM 里看 sysfs

```bash
mount -t sysfs sysfs /sys
mount -t erofs /host/comp2.erofs /mnt
cat /sys/fs/erofs/*/features
```

输出里若含 `dedupe` 即表示启用。

#### 验证 4：定位 `fillgaps` 的使用点

```bash
grep -rn "fillgaps" /sdd/linux/linux-stable/fs/erofs/
```

看它从哪来（`be->keepxcpy`）、在哪用。
顺便理解 D12 缺陷为什么会发生。

## 八、常见误解（重要）

#### 误解 1：内核会做去重计算

**不会**。去重是 **mkfs（构建时）** 的工作。
内核只认特性标志 + 正确处理 deduped 页。

在内核里找"rolling hash 实现"是找不到的。

### 误解 2：dedupe 与 fragment 是一回事

**不是**（06 专题点名最容易混淆）：

| | **dedupe** | **fragment** |
|---|---|---|
| 消除的重复 | **跨文件**的相同数据块 | 压缩后**填不满 pcluster 的零头** |
| 机制 | rolling hash 找相同块 | 零头集中到 packed inode |
| 主要实现 | mkfs | mkfs 集中 + 内核读 |
| 内核字段 | `fillgaps` | `z_fragmentoff` / `packed_inode` |

#### 误解 3：`fillgaps` 只是个无关紧要的标志

不是。它决定 **deduped 页是否被正确初始化**。
传错会导致数据错误——这正是 D12 缺陷的根因。

#### 误解 4：老内核能读去重镜像（只是读不出内容）

不能挂载。`INCOMPAT_DEDUPE` 是 **incompat** 特性，
不认识它的内核会**直接拒绝挂载**（而不是"读错"）。

#### 误解 5：feature 位能区分 dedupe 与 fragment

**不能**。`erofs_fs.h` 里 `EROFS_FEATURE_INCOMPAT_DEDUPE` 与
`EROFS_FEATURE_INCOMPAT_FRAGMENTS` **都是 `0x00000020`**——同位别名。

后果：开了 dedupe 的镜像，`erofs_sb_has_fragments()` 同样返回真，
挂载时也会去 igot packed inode（只要 `packed_nid` 非 0）。

内核真正的区分发生在**更细的层面**：per-lcluster / per-extent 的
`Z_EROFS_LI_PARTIAL_REF`、`Z_EROFS_EXTENT_PLEN_PARTIAL` 标志位。

#### 误解 6：去重会让解压变慢

基本不会。去重省的是**磁盘空间**，
解压侧多出来的开销只是：为未被整页认领的输出槽分配临时页（一次 `alloc_page()`），
**不会引入第二轮解压**。
## 九、与其他特性的关系

| 特性 | 关系 |
|---|---|
| **fragment**（14 专题） | 另一个省空间机制，**最容易与之混淆**（见误解 2） |
| **压缩**（04/05） | 去重作用于**压缩之后**的数据 |
| **ishare**（11 专题） | 去重省**磁盘**，ishare 省**内存**（可叠加） |
| **xattr**（12 专题） | 无直接关系，但都是 incompat/compat 特性体系的一部分 |

## 自测检查点

1. 为什么压缩之后还需要去重？
2. rolling hash 解决什么问题？（不要求算法细节）
3. ⚠️ 去重主要在内核还是 mkfs 做？为什么？
4. `INCOMPAT_DEDUPE` 是 incompat 意味着什么？
5. `fillgaps` 字段的作用是什么？传错会怎样？
6. `fillgaps` 与哪个真实缺陷相关？
7. dedupe 与 fragment 的三点区别？
8. 内核侧对 dedupe 做了哪四步？`partial_decoding` 与 `fillgaps` 各管什么？
9. 怎么确认一个镜像启用了 dedupe？
10. deduped 页在解压时是怎么被处理的？

## 自测答案

<details>
<summary>点击展开</summary>

1. 压缩只消除**单文件内部**冗余，管不了**跨文件**的相同数据块。
   容器镜像里跨文件重复极常见，所以要单独去重。

2. 解决"按固定边界切块时，插入/删除会让后续边界错位、
   去重率暴跌"的问题。它能在**任意位置**算滑动窗口哈希，
   从而找到"内容相同但位置不同"的块。

3. **主要在 mkfs（构建时）**。因为去重要全局扫描与大量计算，
   构建时做一次远比运行时划算；且 EROFS 只读，运行时去重既无必要也太慢。

4. **不认识该特性的内核不能挂载该镜像**（incompat 语义）。
   因为去重改变了数据组织方式，老内核按常规读会读到错的内容——宁可拒绝。

5. 决定"输出空隙（未被整页认领的输出槽）是否分配临时页"。
   传错会导致 deduped 页未正确初始化 → **读到错误数据**。

6. **D12**：`z_erofs_decompress_queue()` 中 `be.keepxcpy` 未初始化，
   而它被当作 `rq.fillgaps` 传下去，栈垃圾值导致处理错误。
   （见 `erofs-analysis/09-八个补丁详解.md`）

7. **①** dedupe 消除跨文件相同块，fragment 处理压缩零头；
   **②** dedupe 靠 rolling hash 匹配，fragment 靠集中到 packed inode；
   **③** 内核字段分别是 `fillgaps` 与 `z_fragmentoff`/`packed_inode`。

8. **①** 挂载时识别 `INCOMPAT_DEDUPE`（不认识则拒绝挂载）；
   **②** `zmap.c` 从 on-disk 标志位（`Z_EROFS_LI_PARTIAL_REF` 等）认出"这段是引用"，
   置 `EROFS_MAP_PARTIAL_REF`；
   **③** `zdata.c` 用 `pcl->partial` 把这件事带进解压请求（`.partial_decoding`）；
   **④** 解压时两个开关：`partial_decoding` 决定**只解压一部分**，
   `fillgaps` 决定**空隙槽是否分配临时页（作为解压落点 / 后续拷贝源）**。
   （全程没有哈希、没有查重——那是 mkfs 的活。）

9. 三种：`dump.erofs -s` 看 feature 位；
   VM 里 `cat /sys/fs/erofs/*/features`；
   或 `grep INCOMPAT_DEDUPE` 看内核定义。

10. 在 `decompressor.c` 里判断 `!*pgo && rq->fillgaps`，
    为真则**分配一个临时页**（`alloc_page()` 不带 `__GFP_ZERO`，**不置零**）；
    该页随后仍会被解压器写入，并作为后续 `memcpy` 的源。

</details>

## 参考
[linux-stable](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)
