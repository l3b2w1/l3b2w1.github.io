---
layout:     post
title:      EROFS fragment and ztailpacking
subtitle:   
date:       2026-09-20
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 14 · 特性专题：fragment 与 ztailpacking

> 相关源码：`zmap.c`（映射时判断）、`zdata.c`（`z_erofs_read_fragment()`）、
> `super.c`（`packed_inode` 初始化）  
> 关键字段：`vi->z_fragmentoff`、`vi->z_idata_size`、`sbi->packed_nid`
>
> 本文回答：**压缩后剩下的"零头"怎么处理** → **packed inode 是什么** →
> **fragment 与 tail-packing 的区别**（最容易混淆的一对概念）→
> **关键结构体与函数** → **一次 fragment 读的来龙去脉**。

## 本专题目标（读完你应该能做到什么）

1. 说清压缩文件的"零头"问题，以及它为什么浪费空间
2. 解释 **packed inode** 是什么、为什么能解决零头问题
3. **清楚区分 fragment 与 tail-packing**（06 专题点名最容易混淆的一对）
4. 看懂 `z_fragmentoff` 为什么要把 pblk 编进高 32 位
5. 解释 `z_idata_size` 的**双重作用**
6. 说清 fragment 数据是怎么被读进 folio 的

## 图解

![fragment 与 ztailpacking：压缩后的零头去哪了](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-20-erofs-32-fragment-ztailpacking.svg)

**一句话**：压缩后每个文件都剩一点零头、填不满一个 pcluster；  
EROFS 把**所有文件的零头集中到 packed inode 里紧凑排列**，几乎不浪费。

自上而下五层：

| 层 | 回答什么 | 一句话 |
|---|---|---|
| **① 问题**（淡红） | 浪费从哪来 | 100KB 文件压到 37.5KB，但要按 4KB pcluster 分配 → 10 块 = 40KB，最后一块浪费 2.5KB；× 上万个文件很可观 |
| **② 解法**（淡绿） | 零头去哪了 | 大家凑一起共享 pcluster → **packed inode**（就是一个普通 EROFS inode，由 superblock 的 `packed_nid` 指定） |
| **③ 两个易混概念**（淡黄） | fragment ≠ tail-packing | fragment 是「**大家凑一起**」（多文件共享，判断 `z_fragmentoff`）；tail-packing 是「**自己塞进 inode**」（单文件独有，判断 `z_idata_size != 0`） |
| **④ 位置编码**（淡蓝） | 怎么记住位置 | `z_fragmentoff = [块号 pblk 高32位][块内偏移 低32位]`，**两步写入、条件不同** |
| **⑤ 怎么读**（淡紫） | 读出来 | `buf.mapping = packed_inode->i_mapping` → `erofs_bread()` + `memcpy_to_folio()`；**不解压**（本来就是压缩后的产物） |

**⚠️ 两个必须记住的澄清**（图底部红框）：

1. **fragment ≠ tail-packing** —— 前者「大家凑一起」，后者「自己塞进 inode」，
   两者**可以同时存在**于同一个文件上。
2. **`z_idata_size` 一字段两用** —— 非 0 即"启用了 ztailpacking"（当标志位），
   其值本身就是 inline 数据的大小（当长度）。

## 一、特性缘由：压缩后的"零头"去哪了

#### 1.1 问题：每个文件压缩后都剩一点

考虑一个 100 KB 的文件，按 4 KB 的 lcluster 压缩：

```
100 KB ÷ 4 KB = 25 个 lcluster
每个压缩后大约 1.5 KB
25 × 1.5 KB = 37.5 KB
```

EROFS 按 **pcluster**（物理压缩簇，通常 4 KB 的整数倍）分配磁盘空间。
若 pcluster 是 4 KB：

```
37.5 KB 的压缩数据，需要 10 个 pcluster = 40 KB
最后一个 pcluster 只用了 1.5 KB，浪费 2.5 KB
```

**每个文件都浪费这么一点**，上万个文件累积起来非常可观。

#### 1.2 解决方案：把零头集中起来

既然每个文件的零头都填不满一个 pcluster，那就——

> **把所有文件的零头集中存到一个特殊 inode 里，共享同一个 pcluster。**

这就是 **fragment**，那个特殊 inode 叫 **packed inode**。

```
文件 A 的零头 ┐
文件 B 的零头 ├─► packed inode ──► 紧凑排列，几乎不浪费
文件 C 的零头 ┘
```

#### 1.3 术语

| 术语 | 含义 |
|---|---|
| **fragment** | 压缩后填不满一个 pcluster 的"零头"数据 |
| **packed inode** | 集中存放所有 fragment 的特殊 inode |
| **tail-packing / ztailpacking** | **另一个机制**：把文件尾部内联进 inode（见 1.4） |
| **`z_idata_size`** | inline 数据大小（同时用于判断 ztailpacking） |

#### 1.4 ⚠️ fragment 与 tail-packing 的区别（重点）

这是 06 专题点名"最容易混淆"的一对：

| | **fragment** | **tail-packing (ztailpacking)** |
|---|---|---|
| 处理对象 | 压缩后的**零头** | 文件**尾部**数据（通常是最后一块） |
| 存放位置 | 集中到 **packed inode** | **内联在 inode 里**（inode 的变长区） |
| 共享 | **多文件共享** pcluster | 单文件独有 |
| 判断字段 | `z_fragmentoff` | `z_idata_size != 0` |
| 目的 | 减少**跨文件**的空间浪费 | 省掉**一个数据块**的分配与寻址 |

⇒ **fragment 是"大家凑一起"，tail-packing 是"自己塞进 inode"**。

两者可以**同时存在**于一个文件上。

## 二、设计理念

#### 理念 1：用特殊 inode 复用现有读路径

packed inode 不是新机制——它就是一个**普通的 EROFS inode**，
只是被指定为"用来装 fragment 的"。

好处：

- 复用现有的 inode 分配、地址映射、读取逻辑
- `z_erofs_read_fragment()` 里直接
  `buf.mapping = packed_inode->i_mapping` 就能读它

⇒ **不发明新机制，而是给现成机制安排一个新用途**。

#### 理念 2：偏移编码进一个 64 位数

`vi->z_fragmentoff` 需要表达 fragment 在 packed inode 里的位置。
EROFS 把它拆成两部分塞进一个 `u64`：

```c
/* ① ztailpacking 时：先记下块内偏移（zmap.c） */
if ((flags & EROFS_GET_BLOCKS_FINDTAIL) && ztailpacking)
        vi->z_fragmentoff = m.nextpackoff;

/* ② fragment 且完整压缩布局时：再把块号编进高 32 位 */
if (fragment && vi->datalayout == EROFS_INODE_COMPRESSED_FULL)
        vi->z_fragmentoff |= (u64)m.pblk << 32;
```

```
z_fragmentoff = [ 块号 pblk (高 32 位) ][ 块内偏移 (低 32 位) ]
```

⚠️ **这两步的条件不一样，别当成一个整体**（上文为便于理解做了简化）：

| 步骤 | 条件 | 写入的部分 |
|---|---|---|
| ① `= m.nextpackoff` | `FINDTAIL` **且** `ztailpacking` | 低 32 位（块内偏移） |
| ② `\|= pblk << 32` | `fragment` **且** `datalayout == COMPRESSED_FULL` | 高 32 位（块号） |

⇒ 只有 **fragment** 才需要块号（数据在 packed inode 里，跨块）；  
单纯的 **ztailpacking** 只用到块内偏移（数据就内联在 inode 的元数据区）。

读取时 `z_fragmentoff + fpos` 作为位置传给 `z_erofs_read_fragment()`。

#### 理念 3：`z_idata_size` 一字段两用

```c
bool ztailpacking = vi->z_idata_size;     /* zmap.c */
```

- 值 **非 0** → 说明有 inline 数据 → **启用了 ztailpacking**
- 值本身 → inline 数据的**大小**

⇒ 既当标志位又当长度，省一个字段。

## 三、实现架构

#### 3.1 对象关系

```
erofs_sb_info
   ├─ packed_nid      ← 从 on-disk superblock 读来
   └─ packed_inode    ← 按 packed_nid igot 出来的 inode
                            │
                            └─ i_mapping
                                  │
                                  ▼
                          所有文件的 fragment 数据（紧凑排列）

每个压缩文件的 erofs_inode
   ├─ z_fragmentoff   ← 我的 fragment 在 packed inode 里的位置
   └─ z_idata_size    ← 我的 inline 尾部数据大小（ztailpacking）
```

#### 3.2 fragment 读取流程

```
读压缩文件，发现某段属于 fragment
        │
        ▼
z_erofs_read_fragment(sb, folio, cur, end, z_fragmentoff + fpos)
        │
        ├─ packed_inode = EROFS_SB(sb)->packed_inode
        │       └─ 为空 → -EFSCORRUPTED
        │
        ├─ buf.mapping = packed_inode->i_mapping      ← 指向 packed inode
        │
        └─ 循环（每次最多一个块）：
              ├─ cnt = min(剩余, 块大小 - 块内偏移)
              ├─ src = erofs_bread(&buf, pos, true)   ← 读 packed inode 的数据
              └─ memcpy_to_folio(folio, cur, src, cnt)
        │
        └─ erofs_put_metabuf(&buf)
```

**注意**：fragment 数据是**未压缩**存放的（它本来就是压缩后的产物，
再压一次收益极小）。所以直接 `memcpy` 即可，不用解压。

## 四、关键结构体与字段

#### 4.1 `erofs_inode` 中的相关字段（`internal.h`）

```c
/* 在压缩用的那个 struct 里 */
unsigned char  z_lclusterbits;
erofs_off_t    z_fragmentoff;      /* ★ fragment 位置（含高 32 位块号）*/
unsigned short z_idata_size;       /* ★ inline 数据大小 / ztailpacking 标志 */
```

#### 4.2 `erofs_sb_info` 中的相关字段（`internal.h`）

```c
struct inode *packed_inode;        /* ★ 装 fragment 的特殊 inode */
erofs_nid_t packed_nid;            /* on-disk superblock 里记的 nid */
```

#### 4.3 on-disk superblock（`erofs_fs.h`）

```c
__le64 packed_nid;      /* nid of the special packed inode */
```

⇒ 镜像制作时 mkfs 决定 packed inode 是哪个，把 nid 写进 superblock；  
内核挂载时读出来（`sbi->packed_nid = le64_to_cpu(dsb->packed_nid)`），
再把它 igot 成 `packed_inode`。

## 五、主要函数

#### 5.1 `z_erofs_read_fragment()`（`zdata.c`）—— 读 fragment

```c
static int z_erofs_read_fragment(struct super_block *sb, struct folio *folio,
                        unsigned int cur, unsigned int end, erofs_off_t pos)
{
        struct inode *packed_inode = EROFS_SB(sb)->packed_inode;
        struct erofs_buf buf = __EROFS_BUF_INITIALIZER;
        unsigned int cnt;
        u8 *src;

        if (!packed_inode)
                return -EFSCORRUPTED;          /* ★ 镜像坏了 */

        buf.mapping = packed_inode->i_mapping;
        for (; cur < end; cur += cnt, pos += cnt) {
                cnt = min(end - cur, sb->s_blocksize - erofs_blkoff(sb, pos));
                src = erofs_bread(&buf, pos, true);
                if (IS_ERR(src)) {
                        erofs_put_metabuf(&buf);
                        return PTR_ERR(src);
                }
                memcpy_to_folio(folio, cur, src, cnt);
        }
        erofs_put_metabuf(&buf);
        return 0;
}
```

要点：

1. **`if (!packed_inode) return -EFSCORRUPTED`** ——
   映射说有 fragment，但镜像没有 packed inode ⇒ **镜像损坏**，明确报错
2. **`buf.mapping = packed_inode->i_mapping`** ——
   把元数据游标指向 packed inode，之后 `erofs_bread` 读的就是它
3. **循环按块切分** —— fragment 可能跨块，要分多次读
4. **`erofs_put_metabuf()`** —— 契约：用完必须释放（02 专题）
5. **直接 `memcpy`，不解压** —— fragment 本身是压缩后的数据

#### 5.2 映射侧（`zmap.c`）

| 位置 | 作用 |
|---|---|
| `bool ztailpacking = vi->z_idata_size;` | 用 `z_idata_size` 判断是否启用 ztailpacking |
| `vi->z_fragmentoff = m.nextpackoff;` | 记录块内偏移 |
| `vi->z_fragmentoff \|= (u64)m.pblk << 32;` | 补上高 32 位块号 |
| `map->m_pa = vi->z_fragmentoff;` | 当作物理地址用 |
| `map->m_plen = vi->z_idata_size;` | 长度 |

#### 5.3 调用点（`zdata.c`）

```c
z_erofs_read_fragment(sb, folio, cur, end,
                      EROFS_I(inode)->z_fragmentoff + fpos);
```

`fpos` 是 folio 内的偏移——加上它才能定位到这个 folio 对应的那段 fragment。


## 六、来龙去脉：完整串一遍

```
① mkfs 阶段
     ├ 逐个压缩文件
     ├ 每个文件压缩后剩下的零头 = fragment
     ├ 建一个特殊的 packed inode
     ├ 把所有 fragment 紧凑写进 packed inode
     ├ 在每个文件的 inode 里记 z_fragmentoff（位置）
     └ 把 packed inode 的 nid 写进 on-disk superblock
        │
② 挂载
     ├ sbi->packed_nid = le64_to_cpu(dsb->packed_nid)
     └ 按 nid 把 packed inode igot 出来 → sbi->packed_inode
        │
③ 读某个压缩文件，碰到 fragment 段
        │
④ z_erofs_read_fragment(sb, folio, cur, end, z_fragmentoff + fpos)
        ├ 确认 packed_inode 存在（否则 -EFSCORRUPTED）
        ├ buf.mapping 指向 packed inode
        ├ 按块循环 erofs_bread + memcpy_to_folio
        └ erofs_put_metabuf
        │
⑤ 数据进入 folio → 读完成
```

**效果**：原本每个文件都要浪费的零头空间，
现在被所有文件**挤在一起共享**，浪费降到几乎为零。

## 七、动手验证

#### 验证 1：确认镜像有 packed inode

```bash
/opt/erofs-utils/bin/dump.erofs -s /tmp/erofs-lab/sub512m.erofs
```

看 superblock 输出里有没有 packed inode 相关信息（nid）。

#### 验证 2：确认挂载后 packed_inode 被建立

```bash
cd /sdd/linux/linux-stable/fs/erofs
grep -rn "packed_inode\|packed_nid" super.c inode.c
```

追踪它从 `packed_nid` 到 `packed_inode` 的建立过程。

#### 验证 3：读源码确认 memcpy（不解压）

在 `z_erofs_read_fragment()` 里确认是 `memcpy_to_folio()`
而**没有**任何解压调用——验证"fragment 不再压缩"这一点。

## 八、常见误解（重要）

#### 误解 1：fragment 和 tail-packing 是一回事

**不是**（见 1.4）：

- **fragment** = 多个文件的压缩零头，**集中到 packed inode**
- **tail-packing** = 单个文件的尾部，**内联进自己的 inode**

#### 误解 2：fragment 数据还会再压缩一次

不会。fragment 本身就是压缩的产物，再压收益极小。
`z_erofs_read_fragment()` 里只有 `memcpy`，没有解压。

### 误解 3：`z_idata_size` 只是个大小

它还是 **ztailpacking 的开关**：`bool ztailpacking = vi->z_idata_size;`
非 0 即表示启用。

#### 误解 4：`z_fragmentoff` 只是块内偏移

不只。它是**块号（高 32 位）+ 块内偏移（低 32 位）**打包成的 `u64`。

#### 误解 5：packed inode 是一种新的特殊 inode 类型

不是。它就是**普通的 EROFS inode**，只是被指定用来装 fragment。
正因如此，读它的代码能直接复用 `erofs_bread`。

## 九、与其他特性的关系

| 特性 | 关系 |
|---|---|
| **压缩路径**（04） | fragment 是压缩的**副产物**，只读压缩文件才有 |
| **dedupe / rolling hash**（15） | 另一个省空间机制，思路不同（块级去重 vs 零头集中） |
| **metabox**（18） | packed inode 的数据也可能在 metabox 里 |
| **多设备**（13） | packed inode 可以位于任意设备上，照常走 `erofs_map_dev` |

## 自测检查点

1. fragment 想解决什么问题？
2. packed inode 是什么？它是不是一种特殊的 inode 类型？
3. fragment 与 tail-packing 的区别是什么（至少三点）？
4. `z_fragmentoff` 的高 32 位和低 32 位分别表示什么？
5. `z_idata_size` 有哪两个作用？
6. 读 fragment 时为什么直接 `memcpy` 而不解压？
7. 若映射显示有 fragment，但 `packed_inode` 为空，会发生什么？
8. `z_erofs_read_fragment()` 里 `buf.mapping` 被设成了什么？为什么？
9. fragment 数据可能存在哪些位置？（提示：metabox）
10. 为什么多个文件的零头挤在一起能省空间？

## 自测答案

<details>
<summary>点击展开</summary>

1. 压缩文件剩下的"零头"填不满一个 pcluster，
   每个文件都浪费一点，累积起来很可观。

2. 集中存放所有 fragment 的特殊 inode。
   **不是新类型**——它就是普通的 EROFS inode，只是被指派了这个用途，
   因此可以直接用 `erofs_bread` 读它。

3. **①** 对象：fragment 是压缩零头，tail-packing 是文件尾部数据；
   **②** 位置：fragment 集中到 packed inode，tail-packing 内联进自己的 inode；
   **③** 共享：fragment 多文件共享 pcluster，tail-packing 单文件独有。

4. **高 32 位 = 块号（pblk）**，**低 32 位 = 块内偏移**。
   打包成一个 `u64`：`z_fragmentoff |= (u64)m.pblk << 32;`

5. **①** 表示 inline（tail-packing）数据的**大小**；
   **②** 非 0 即作为 **ztailpacking 的开关**（`bool ztailpacking = vi->z_idata_size;`）。

6. fragment 本身已经是**压缩后的产物**，再压缩收益极小。
   代码里只有 `memcpy_to_folio()`，没有任何解压调用。

7. 返回 **`-EFSCORRUPTED`**（镜像损坏）——
   映射说有 fragment 却没有 packed inode，说明镜像不自洽。

8. 被设为 **`packed_inode->i_mapping`**。
   这样后续的 `erofs_bread(&buf, ...)` 读的就是 packed inode 的数据，
   而不是当前文件的。

9. 常规数据区，也可能在 **metabox** 里（视镜像配置而定）。

10. 因为单个文件的零头填不满一个 pcluster（分配粒度），
    多个零头**拼在一起**就能把 pcluster 填满，
    把"每文件各浪费一点"变成"总共只浪费一点"。

</details>

## 参考
[linux-stable](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)
