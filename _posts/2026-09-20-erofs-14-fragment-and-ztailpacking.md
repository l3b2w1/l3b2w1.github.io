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
4. 看懂 `z_fragmentoff` 是**64 位字节偏移**，以及高 32 位为什么借 `pblk` 槽位存放
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
| **④ 位置编码**（淡蓝） | 怎么记住位置 | `z_fragmentoff` = **packed inode 内的 64 位字节偏移**；镜像里低 32 位存 `h_fragmentoff`，高 32 位**借** `di_u.blkaddr`（内核侧 `m.pblk`）存放，读时拼回去 |
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
| 判断字段 | `vi->z_advise & Z_EROFS_ADVISE_FRAGMENT_PCLUSTER`<br/>（另需 superblock 的 `EROFS_FEATURE_INCOMPAT_FRAGMENTS`） | `z_idata_size != 0` |
| 位置字段 | `z_fragmentoff` | ——（就在 inode 元数据区） |
| 目的 | 减少**跨文件**的空间浪费 | 省掉**一个数据块**的分配与寻址 |

⇒ **fragment 是"大家凑一起"，tail-packing 是"自己塞进 inode"**。

> **⚠️ 别把 `z_fragmentoff` 当成判据**：它是**位置**字段（记"我的零头放在哪"），不是开关。
> 真正的开关是两个：`zmap.c` 里 `bool fragment = vi->z_advise & Z_EROFS_ADVISE_FRAGMENT_PCLUSTER;`
> 以及挂载时 `erofs_sb_has_fragments(sbi)`（即 superblock 的 `EROFS_FEATURE_INCOMPAT_FRAGMENTS`）
> ——后者决定要不要去 `erofs_iget()` 那个 packed inode。

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

`vi->z_fragmentoff` 要表达的是「我的零头在 packed inode 里的位置」——
**它是一个 64 位的字节偏移**（以 packed inode 的数据区起点为 0）。

```c
/* ① ztailpacking 时：先记下位置本身（zmap.c） */
if ((flags & EROFS_GET_BLOCKS_FINDTAIL) && ztailpacking)
        vi->z_fragmentoff = m.nextpackoff;

/* ② fragment 且完整压缩布局时：再把高 32 位补上去 */
if (fragment && vi->datalayout == EROFS_INODE_COMPRESSED_FULL)
        vi->z_fragmentoff |= (u64)m.pblk << 32;
```

⚠️ **这两步的条件不一样，别当成一个整体**：

| 步骤 | 条件 | 写入的部分 |
|---|---|---|
| ① `= m.nextpackoff` | `FINDTAIL` **且** `ztailpacking` | 位置本身（元数据区内的字节偏移） |
| ② `\|= pblk << 32` | `fragment` **且** `datalayout == COMPRESSED_FULL` | 高 32 位 |

#### ⚠️ 最关键的一点：`m.pblk` 在这里不是块号

槽位名叫 `blkaddr` / `pblk`，装的却**不是块地址**——mkfs 只是**借**这个 32 位字段
存放偏移的高半部分（`erofs-utils/lib/compress.c`）：

```c
di.di_u.blkaddr = cpu_to_le32(inode->fragmentoff >> 32);   /* 高 32 位借 blkaddr */
h.h_fragmentoff = cpu_to_le32(inode->fragmentoff);         /* 低 32 位 */
/* extents（简化）形态下则借 plen / pstart 两个槽位分别放低 32 位与高 32 位 */
```

内核再把它拼回高半部分，得到一个完整的字节偏移。三条独立证据：

1. `erofs_bread(buf, offset)` 的参数是**字节偏移**（`internal.h`），
   而 `z_fragmentoff` 是**直接**传给它的，中间没有任何 `erofs_pos()` 换算
2. `zmap.c` 里 `map->m_pa = vi->z_fragmentoff` —— `m_pa` 是字节地址，同样不做换算
3. mkfs 注释写明「packed inode 大于 4 GiB 时，完整的 fragmentoff 会改用
   noncompact 布局记录」——若是块号，根本不会在这个量级上讨论

⇒ 正确读法：**`z_fragmentoff` = packed inode 内的 64 位字节偏移**。

常见镜像里 packed inode 远小于 4 GiB，**高 32 位就是 0**，
此时低 32 位本身就是完整偏移——这也是为什么步骤 ① 直接赋值就能用。

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
   └─ packed_inode    ← erofs_iget(sb, packed_nid) 出来的 inode（前提：erofs_sb_has_fragments()）
                            │
                            └─ i_mapping
                                  │
                                  ▼
                          所有文件的 fragment 数据（紧凑排列）

每个压缩文件的 erofs_inode
   ├─ z_fragmentoff   ← 我的 fragment 在 packed inode 里的位置
   └─ z_idata_size    ← 我的 inline 尾部数据大小（ztailpacking）
```

###### 布局图

零头在 packed inode 里怎么排、各自怎么找回自己的那段，上面是对象关系，下面把它画成**磁盘布局**：

![disk layout](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-20-erofs-33-fragment-packed-layout.dot)

三个文件的零头用三种颜色区分，**文件 C 那段故意跨了块边界**——
正是它逼出了 `z_erofs_read_fragment()` 里那个「按块切分」的循环
（一次 `erofs_bread()` 只能读一块，跨块就得读两次）。
图的下半部回答两件事：位置怎么编码（`z_fragmentoff`）、读的时候怎么拿它去取数据。

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
再用 `erofs_iget(sb, sbi->packed_nid)` 拿到 `packed_inode`。

**注意有前提**：`super.c` 里是

```c
if (erofs_sb_has_fragments(sbi) && sbi->packed_nid) {
        inode = erofs_iget(sb, sbi->packed_nid);
        ...
        sbi->packed_inode = inode;
}
```

⇒ 镜像没开 `FRAGMENTS` 特性、或 `packed_nid` 为 0，**根本不会有 packed inode**；
这也解释了后面 `z_erofs_read_fragment()` 里 `if (!packed_inode) return -EFSCORRUPTED` 的由来。

---

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
| `vi->z_fragmentoff \|= (u64)m.pblk << 32;` | 补上高 32 位（借 `m.pblk` 槽位，**它不是块号**） |
| `map->m_pa = vi->z_fragmentoff;` | 当作物理地址用 |
| `map->m_plen = vi->z_idata_size;` | 长度 |

#### 5.3 调用点（`zdata.c`）

```c
if (map->m_flags & EROFS_MAP_FRAGMENT) {
        erofs_off_t fpos = offset + cur - map->m_la;

        err = z_erofs_read_fragment(inode->i_sb, folio, cur,
                        cur + min(map->m_llen - fpos, end - cur),
                        EROFS_I(inode)->z_fragmentoff + fpos);
        if (err)
                break;
}
```

两处细节（前面为便于理解做了简化，这里按源码补全）：

- **`fpos` 不是"folio 内的偏移"**：它是 `offset + cur - map->m_la`，
  即**这一次要读的数据在整个 fragment 里的起点**（相对 fragment 开头的偏移）。
  folio 内偏移是 `cur`，映射起点是 `map->m_la`，二者相减才得到 fragment 内的位置。
- **第四个参数不是 `end`**：是 `cur + min(map->m_llen - fpos, end - cur)`，
  即"从 `cur` 起，取『fragment 剩余长度』与『folio 剩余空间』中的较小者"。

⇒ `z_fragmentoff + fpos` 就是这一次要读的字节在 packed inode 里的绝对位置
（`z_fragmentoff` 本身即字节偏移，直接相加，无需任何换算）。

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
     └ erofs_iget(sb, packed_nid) → sbi->packed_inode（前提：erofs_sb_has_fragments()）
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

#### 误解 4：`z_fragmentoff` 是「块号 + 块内偏移」

**不是**（这是最容易望文生义的一处）。它整体是 **packed inode 内的 64 位字节偏移**。
`m.pblk` 只是被 mkfs **借**来存放高 32 位的槽位——槽位名叫 `blkaddr`，装的却不是块地址。
判据：`erofs_bread(buf, offset)` 收的是字节偏移，而 `z_fragmentoff` 是直接传给它的，
中间没有任何换算（详见理念 2）。

#### 误解 5：packed inode 是一种新的特殊 inode 类型

不是。它就是**普通的 EROFS inode**，只是被指定用来装 fragment。
正因如此，读它的代码能直接复用 `erofs_bread`。

## 九、与其他特性的关系

| 特性 | 关系 |
|---|---|
| **压缩路径**（04） | fragment 是压缩的**副产物**，只读压缩文件才有 |
| **dedupe / rolling hash**（15） | 另一个省空间机制，思路不同（块级去重 vs 零头集中） |
| **metabox**（18） | **并列关系，不是包含关系**：xattr 长前缀表可以放在 metabox **或** packed inode 的数据区（官方文档原文 "embedded in the metabox or packed inode's data region"；`xattr.c` 里是 `if (erofs_sb_has_metabox(sbi)) ... else if (sbi->packed_inode)`）。**fragment 数据本身不经过 metabox**——它固定走 `packed_inode->i_mapping` |
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
9. 挂载时，满足什么条件内核才会去建立 `packed_inode`？
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

4. **整体是 packed inode 内的 64 位字节偏移**。
   镜像里低 32 位存 `h_fragmentoff`，高 32 位借 `di_u.blkaddr`（内核侧 `m.pblk`）存放，
   内核用 `z_fragmentoff |= (u64)m.pblk << 32` 拼回去。
   ⚠️ **不是**「块号 + 块内偏移」——`erofs_bread()` 收的是字节偏移，中间没有换算。

5. **①** 表示 inline（tail-packing）数据的**大小**；
   **②** 非 0 即作为 **ztailpacking 的开关**（`bool ztailpacking = vi->z_idata_size;`）。

6. fragment 本身已经是**压缩后的产物**，再压缩收益极小。
   代码里只有 `memcpy_to_folio()`，没有任何解压调用。

7. 返回 **`-EFSCORRUPTED`**（镜像损坏）——
   映射说有 fragment 却没有 packed inode，说明镜像不自洽。

8. 被设为 **`packed_inode->i_mapping`**。
   这样后续的 `erofs_bread(&buf, ...)` 读的就是 packed inode 的数据，
   而不是当前文件的。

9. `super.c` 里是 `if (erofs_sb_has_fragments(sbi) && sbi->packed_nid)` 才
   `erofs_iget(sb, sbi->packed_nid)` —— 两个条件缺一不可：
   镜像必须开了 `EROFS_FEATURE_INCOMPAT_FRAGMENTS` 特性，且 `packed_nid` 非 0。
   ⚠️ 早期版本这里写"还可能放在 metabox 里"是错的：fragment 数据固定走
   `packed_inode->i_mapping`，与 metabox 无此关系（metabox 只是 xattr 长前缀表的
   另一处**并列**落点）。

10. 因为单个文件的零头填不满一个 pcluster（分配粒度），
    多个零头**拼在一起**就能把 pcluster 填满，
    把"每文件各浪费一点"变成"总共只浪费一点"。

</details>

## 参考
[linux-stable](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)
