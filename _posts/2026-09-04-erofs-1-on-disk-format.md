---
layout:     post
title:      EROFS on-disk format
subtitle:   EROFS 镜像格式
date:       2026-09-04
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - fs
	- erofs
	- ai
---

# 阶段 1：on-disk 格式

> 本章所有数字都来自**真实镜像**，不是编造的示例。
> 你可以照着 1.9 节的命令一步步复现，看到和我一样的结果。

---

## 本阶段目标

读完这一章，你应该能够：

1. 说出 EROFS 镜像里什么位置固定、什么位置自由
2. 解释 superblock 里那几个关键字段各自"内核拿它来干什么"
3. **给你一个 nid，算出这个 inode 在磁盘的哪个字节**
4. 说清 5 种 datalayout 各自用来存什么样的文件，并能看 `dump.erofs` 的输出判断属于哪种
5. 解释 `union erofs_inode_i_u` 为什么是 union——它体现了什么设计思想
6. 说清目录项（dirent）的"头尾分离"设计
7. 能自己用 `mkfs.erofs` 造出不同布局的镜像并用 `dump.erofs` 验证

## 1.1 先做个实验（动手优先）

- 工具：`mkfs.erofs` 和 `dump.erofs`

在讲任何概念之前，先造一个镜像看看。这一节的所有命令都可以直接复制执行。

```bash
cd /tmp && rm -rf erofs-lab && mkdir -p erofs-lab/src && cd erofs-lab

# 造三种不同特点的文件
printf 'hello' > src/tiny.txt                     # 5 字节，极小
head -c 100000 /dev/urandom > src/big.bin         # 100KB 随机数据，不可压缩

# 造镜像（非压缩）
/sdd/erofs/erofs-utils/mkfs/mkfs.erofs plain.erofs src
```

输出：

```
Filesystem total blocks: 31 (of 4096-byte blocks)
Filesystem total inodes: 203
Filesystem total metadata blocks: 7
```

现在看超级块：

```bash
/sdd/erofs/erofs-utils/dump/dump.erofs -s plain.erofs
```

```
Filesystem magic number:                      0xE0F5E1E2
Filesystem blocksize:                         4096
Filesystem blocks:                            31
Filesystem inode metadata start block:        0
Filesystem root nid:                          128
Filesystem sb_size:                           128
Filesystem inode count:                       203
```

再看某个具体文件：

```bash
/sdd/erofs/erofs-utils/dump/dump.erofs --path=/tiny.txt plain.erofs
```

```
Path : /tiny.txt
Size: 5  On-disk size: 5  regular file
NID: 126   Links: 1   Layout: 2   Compression ratio: 100.00%
Inode size: 32   Xattr size: 16
```

注意 **`Layout: 2`** 和 **`NID: 126`** 这两个数字——它们是本章的主角。

**带着这两个问题往下读：**
- `Layout: 2` 是什么意思？（1.5 节）
- 内核拿到 `nid = 126` 之后，怎么知道这个 inode 在磁盘的哪里？（1.4 节）

## 1.2 镜像整体布局

![镜像布局](img/2026-09-04-erofs-02-image-layout.svg)

**最重要的一句话：除了 superblock，没有什么是位置固定的。**

EROFS 官方材料对这个设计的描述是：

> "Mixed metadata with data (In other words, flexible enough for mkfs to play with it)"

**元数据与数据混合存放，位置完全由 mkfs 决定。** 这和 ext4 那种"块组 + 位图 + inode 表"的固定布局截然不同。

上面那个真实镜像（31 块）里的实际情况：

| 偏移 | 内容 |
|---|---|
| 0 ~ 128 | superblock |
| 128 ~ | 元数据：inode、dirent（紧凑排列） |
| **1264** | big.bin 的**尾部 1696 字节**（tail-packing，塞在元数据区里！） |
| 8192 ~ 106496 | big.bin 的主体数据（块 2 起） |

注意 1264 这个偏移——**文件数据出现在元数据区内部**。
这正是"混合存放"的直观体现，也是 tail-packing（尾部内联）的效果。

> **为什么敢这么设计？** 因为 EROFS 是只读的。
> 所有布局在 mkfs 时就定死了，运行时不需要增删改，
> 所以不需要预留空间、不需要可变的索引结构。
> **只读换来了布局上的极大自由。**


## 1.3 superblock：唯一位置固定的东西

superblock 永远在偏移 0，大小 128 字节起（`sb_size` 字段可让它更大）。
结构定义在 `erofs_fs.h:54`。

全字段有二十多个，**现在只需要记住这 6 个**：

| 字段 | 实测值 | 内核拿它来干什么 |
|---|---|---|
| `magic` | `0xE0F5E1E2` | 判断这是不是 EROFS 镜像，不是就拒绝挂载 |
| `blkszbits` | 12（=4096） | 块大小的位偏移。后续所有"块↔字节"换算都靠它 |
| `blocks` | 31 | 镜像总块数，用于边界检查 |
| `meta_blkaddr` | 0 | **元数据区起始块**，inode 寻址的第一项 |
| `rootnid` | 128 | 根目录的 nid，挂载的起点 |
| `feature_incompat` | 空 | 有不认识的不兼容特性就拒绝挂载 |

其中 **`blkszbits` 是理解后续一切换算的钥匙**：

- 块 → 字节：`blk << blkszbits`
- 字节 → 块：`off >> blkszbits`
- 字节 → 块内偏移：`off & ((1 << blkszbits) - 1)`

内核里对应的写法是 `erofs_pos()` / `erofs_blknr()` / `erofs_blkoff()`。

> ⚠️ **不要以为块大小永远是 4096。** 阶段 0 讲过：
> `super.c:272` 校验的合法范围是 `[9, PAGE_SHIFT]`，即 512 字节到页大小。
> 4096 只是 mkfs 的默认值。

## 1.4 nid → 磁盘偏移：一行公式

![nid 寻址](img/2026-09-04-erofs-04-nid-to-inode.svg)

EROFS 里**没有 inode 表**。给你一个 nid，你得**算**出它在哪。

公式在 `internal.h:306-315`：

```c
static inline erofs_off_t erofs_iloc(struct inode *inode)
{
        struct erofs_sb_info *sbi = EROFS_I_SB(inode);
        erofs_nid_t nid_lo = EROFS_I(inode)->nid & EROFS_DIRENT_NID_MASK;

        if (erofs_inode_in_metabox(inode))
                return nid_lo << sbi->islotbits;
        return erofs_pos(inode->i_sb, sbi->meta_blkaddr) +
                (nid_lo << sbi->islotbits);
}
```

拆成两个部件：

```
inode 的磁盘偏移 = meta_blkaddr × 块大小  +  nid × inode槽大小
                  └──── 元数据区起点 ────┘   └── 槽内偏移 ──┘
```

**部件 2 里的 `islotbits` 是什么？**

它是"inode 槽大小"的位偏移，在 `super.c:319` 初始化：

```c
sbi->islotbits = ilog2(sizeof(struct erofs_inode_compact));
```

inode 有两种尺寸：

| 类型 | 大小 | islotbits | 什么时候用 |
|---|---|---|---|
| compact（`erofs_fs.h:161`） | 32 字节 | 5 | 时间戳较短、uid/gid 较小的普通情况 |
| extended | 64 字节 | 6 | 需要完整时间戳/大 uid-gid 时 |

**用真实数字验证一遍**：

```
meta_blkaddr = 0,  root nid = 128,  islotbits = 5（compact，32 字节）

root inode 偏移 = 0 × 4096 + 128 × 32 = 4096
```

即块 1 的开头。superblock 只占块 0 的前 128 字节，
所以块 0 剩下的空间也是元数据，root inode 顺延到块 1——**完全说得通**。

> **为什么敢用"算"而不用索引结构？** 还是那句话：只读。
> 不需要插入删除，就不需要 B 树或位图。
> 一次乘法定位一个 inode，这是只读文件系统换来的最大红利。

**metabox 例外**（`internal.h:311-312`）：nid 最高位为 1 时，
该 inode 存放在 metabox 里，此时公式**不加**元数据区起点。
这个先记住有这回事，阶段 6 讲。

---

## 1.5 ⭐ 5 种 datalayout

![5 种 datalayout](img/2026-09-04-erofs-03-datalayout-five.svg)

**这是理解 EROFS on-disk 格式最关键的一节。**

datalayout 是 inode 里 `i_format` 字段的低 3 位，定义在 `erofs_fs.h:105-110`：

```c
EROFS_INODE_FLAT_PLAIN         = 0,
EROFS_INODE_COMPRESSED_FULL    = 1,
EROFS_INODE_FLAT_INLINE        = 2,
EROFS_INODE_COMPRESSED_COMPACT = 3,
EROFS_INODE_CHUNK_BASED        = 4,
```

它决定两件事：**（a）inode 后面跟的是什么；（b）`union erofs_inode_i_u` 该怎么解释。**

逐一来看，每个都配上实测案例：

### 0 — FLAT_PLAIN：数据在独立块

最朴素的一种：文件数据放在若干独立块里，inode 只记起始块号。

**实测**（1MB 稀疏文件，未开 chunksize）：
```
Path : /sparse.bin
Size: 1048576  On-disk size: 1048576
NID: 41   Layout: 0
 Ext:   logical offset   |  length :     physical offset    |  length
   0:        0.. 1048576 | 1048576 :       4096..   1052672 | 1048576
```

注意 `On-disk size` 等于 `Size`——**空洞也被分配了**，占了整整 1MB。
（后面 CHUNK_BASED 会解决这个浪费。）

### 2 — FLAT_INLINE：尾部数据内联

⚠️ **这是最容易搞错的一种**。名字里的 "inline" **不是**"整个文件内联"，
而是"**尾部不足一块的数据**内联"。

**实测①**（5 字节的 tiny.txt，整个内联）：
```
Size: 5  On-disk size: 5
NID: 126   Layout: 2
```

**实测②**（100KB 的 big.bin，**主体在独立块，只有尾巴内联**）：
```
Size: 100000  On-disk size: 100000
NID: 38   Layout: 2
 Ext:   logical offset   |  length :     physical offset    |  length
   0:        0..   98304 |   98304 :       8192..    106496 |   98304
   1:    98304..  100000 |    1696 :       1264..      2960 |    1696
```

看第二个 extent：**物理偏移 1264**——那在元数据区内部。
最后 1696 字节不足一块，mkfs 就把它塞在 inode 后面，省掉一个整块。

> **所以判断标准不是"文件大不大"，而是"有没有尾巴需要内联"。**
> 100KB 的文件照样可以是 FLAT_INLINE。

这个设计叫 **tail-packing**。EROFS 早在 2019 年的第一份官方演讲里就把它列为特性：
"Support tail-end data inline"（T1:198）。

### 3 — COMPRESSED_COMPACT：压缩 + 紧凑索引

**实测**（400KB 高度可压缩的文本）：
```
Path : /rep.txt
Size: 400000  On-disk size: 4096
NID: 41   Layout: 3   Compression ratio: 1.02%
 Ext:   logical offset   |  length :     physical offset    |  length
   0:        0..  400000 |  400000 :       4096..      8192 |    4096
```

**400000 字节压成 4096 字节**——只占一个块。压缩率 1.02%。

"COMPACT" 指的是**索引用紧凑格式**存储。
压缩文件的"逻辑偏移 → 物理位置"需要索引（因为压缩后长度不定），
索引本身也要占空间，所以有小索引（compact）和大索引（non-compact）两种格式。
**区别留到阶段 4 讲**，现在只知道有这回事。

### 1 — COMPRESSED_FULL：压缩 + 完整索引

与 3 的区别只在索引格式：索引用完整（非紧凑）格式。
当索引项太多、紧凑格式装不下时就用它。

（本章的实测样例里没触发到它，阶段 4 会补上。）

### 4 — CHUNK_BASED：按块分块

把文件切成固定大小的 chunk，每个 chunk 独立寻址。
**它的关键能力是表达"空洞"**。

**实测**（同样是那个 1MB 稀疏文件，这次加 `--chunksize=65536`）：
```
Path : /sparse.bin
Size: 1048576  On-disk size: 1048576
NID: 42   Layout: 4
 Ext:   logical offset   |  length :     physical offset    |  length
   0:        0..   65536 |   65536 : 17592186040320..17592186105856 |   65536
   1:    65536..  131072 |   65536 : 17592186040320..17592186105856 |   65536
```

那个离谱的物理偏移 `17592186040320` 是什么？

```
17592186040320 = 0xFFFFFFFF × 4096
```

即块号是 `0xFFFFFFFF`，正是 `EROFS_NULL_ADDR`（`erofs_fs.h:265` 定义它为 -1）。
**这是"空洞"的表示法：这个 chunk 没有对应的磁盘块。**

效果非常实在：

| 镜像 | Layout | 实际占磁盘 |
|---|---|---|
| `chunk.erofs` | 0 FLAT_PLAIN | 1052672 字节 |
| `chunk2.erofs` | 4 CHUNK_BASED | **69632 字节** |

同样的 1MB 稀疏文件，**省了 93%**。

---

## 1.6 `union erofs_inode_i_u`：一个字段，四种含义

inode 里有一个 union，定义在 `erofs_fs.h:147`：

```c
union erofs_inode_i_u {
        __le32 blocks_lo;      /* total blocks count (if compressed inodes) */
        __le32 startblk_lo;    /* starting block number (if flat inodes) */
        __le32 rdev;           /* device ID (if special inodes) */
        struct erofs_inode_chunk_info c;
};
```

同样 4 个字节，含义由 **datalayout** 决定：

| datalayout | 这个 union 解释为 |
|---|---|
| 0 / 2（flat） | `startblk_lo`：数据起始块号 |
| 1 / 3（compressed） | `blocks_lo`：文件占用的总块数 |
| 4（chunk-based） | `c`：chunk 的格式信息（chunk 大小的位偏移等） |
| 设备文件 | `rdev`：设备号 |

**为什么用 union 而不是四个独立字段？**

因为只读文件系统的 inode 必须尽可能小。
inode 每大 4 字节，几百万个文件就多占几 MB。
而一个 inode **只会**是其中一种布局，所以让它们共用 4 个字节是纯粹的收益。

> 这也解释了为什么 EROFS 有两种 inode 尺寸（32 / 64 字节）：
> 能用紧凑的就用紧凑的。空间敏感场景下，每个字节都要省。

**这个 union 是理解 EROFS 设计哲学的一个窗口**：
布局在 mkfs 时定死 → 运行时不需要改变 → 所以能把互斥的字段压成一个 union。

## 1.7 目录与 dirent：头尾分离

目录在 EROFS 里也是**一个文件**，它的内容就是一串目录项（dirent）。

dirent 是**定长 12 字节**，定义在 `erofs_fs.h:281`：

```c
struct erofs_dirent {
        __le64 nid;      /* node number */
        __le16 nameoff;  /* start offset of file name */
        __u8 file_type;  /* file type */
        __u8 reserved;   /* reserved */
} __packed;
```

注意：**dirent 里没有存文件名字符串**，只有一个 `nameoff` 偏移。

文件名存在**块的后半部分**，从块尾往前排：

```
一个目录块（4096 字节）
┌──────────────────────────────────────────┐
│ dirent[0] │ dirent[1] │ dirent[2] │ ...  │  ← 从块头往后，定长
├──────────────────────────────────────────┤
│         （空闲）                          │
├──────────────────────────────────────────┤
│ "…" │ "readme.txt" │ "hello.txt" │ ...   │  ← 文件名，从块尾往前
└──────────────────────────────────────────┘
```

为什么这么设计？**因为 dirent 定长了。**

如果文件名直接嵌在 dirent 里，dirent 就变成变长结构：
查找时无法用"第 N 个 dirent"直接定位，只能从头遍历。
把名字挪出去之后：

- dirent 是 12 字节定长 → 可以用**二分查找**
- `nameoff` 指向名字 → 需要时再去取

**查找一个文件名的基本流程**：
1. 算出名字的 hash
2. 在目录块的 dirent 数组里二分查找
3. 用 `nameoff` 取出候选的名字字符串，做**精确比对**（hash 会碰撞，必须比对）
4. 命中 → 拿到 `nid` → 用 1.4 节的公式算 inode 位置

第 3 步很重要：**hash 只用来缩小范围，最终靠字符串比对确认**。

## 1.8 压缩文件的一瞥（阶段 4 的伏笔）

对比一下非压缩和压缩文件在磁盘上的样子：

| | 非压缩（FLAT_PLAIN） | 压缩（COMPRESSED_*） |
|---|---|---|
| 逻辑 8KB → 物理位置 | 简单算术：偏移 ÷ 块大小 | **必须查索引** |
| 磁盘上一段连续数据对应逻辑多少？ | 一一对应 | 不定，取决于压缩率 |
| 读出来能直接用吗 | 能 | 不能，要解压 |

关键点：**压缩后长度不定，所以"第 N 个逻辑块在磁盘哪里"这个问题没有算术解，只能查表。**

那张表就是**压缩索引**，它存在 inode 后面（datalayout 1/3 时）。
索引有三种格式（non-compacted / compacted_2b / compacted_1），
pcluster 的生命周期管理也比非压缩复杂得多。

**这些都是阶段 4 的内容。现在只需要建立一个认识：**
压缩让"读"从一步（`算`）变成四步（`查索引 → 读 → 解压 → 回填缓存`）。

## 1.9 完整实操：造出四种布局

把本章用到的实验整合成一份可复现的脚本。

```bash
cd /tmp && rm -rf erofs-lab && mkdir -p erofs-lab && cd erofs-lab
M=/sdd/erofs/erofs-utils/mkfs/mkfs.erofs
D=/sdd/erofs/erofs-utils/dump/dump.erofs

# ---------- ① FLAT_INLINE（小文件整体内联）----------
mkdir src && printf 'hello' > src/tiny.txt
head -c 100000 /dev/urandom > src/big.bin
$M plain.erofs src
$D --path=/tiny.txt plain.erofs     # Layout: 2
$D --path=/big.bin -e plain.erofs   # Layout: 2，注意尾部 extent 在偏移 1264

# ---------- ② COMPRESSED_COMPACT ----------
mkdir src2
yes "EROFS is a read-only compressed file system" | head -c 400000 > src2/rep.txt
$M -zlz4hc comp2.erofs src2
$D --path=/rep.txt comp2.erofs      # Layout: 3，400000 → 4096 字节

# ---------- ③ FLAT_PLAIN vs CHUNK_BASED（稀疏文件对比）----------
mkdir src3 && truncate -s 1M src3/sparse.bin
dd if=/dev/urandom of=src3/sparse.bin bs=4096 seek=100 count=1 conv=notrunc

$M chunk.erofs src3                 # 默认
$M --chunksize=65536 chunk2.erofs src3

$D --path=/sparse.bin chunk.erofs   # Layout: 0
$D --path=/sparse.bin -e chunk2.erofs   # Layout: 4，空洞显示为 17592186040320
ls -l chunk.erofs chunk2.erofs      # 1052672 vs 69632 —— 省 93%

# ---------- ④ 看超级块 ----------
$D -s plain.erofs
```

**建议每个都实际跑一遍。** 看到 `Layout:` 后面的数字在变，
比读十遍概念说明都管用。

## 术语速查

| 术语 | 含义 | 出处 |
|---|---|---|
| nid | inode 编号，用于算出 inode 的磁盘位置 | 1.4 |
| `meta_blkaddr` | 元数据区起始块 | `erofs_fs.h:68` |
| `islotbits` | inode 槽大小的位偏移（32B→5，64B→6） | `super.c:319` |
| datalayout | inode 里决定"数据怎么找"的 3 位字段 | `erofs_fs.h:105-110` |
| tail-packing | 尾部不足一块的数据内联到 inode 后 | 1.5 |
| chunk | chunk-based 文件里的固定大小分块 | 1.5 |
| `EROFS_NULL_ADDR` | 空块地址，值为 -1，表示"没有对应块" | `erofs_fs.h:265` |
| dirent | 定长 12 字节的目录项，名字靠 `nameoff` 索引 | `erofs_fs.h:281` |
| compact / extended inode | 32 字节 / 64 字节两种 inode 尺寸 | 1.4 |


## 自测检查点

1. EROFS 镜像里，位置固定不变的东西是什么？为什么其他都不固定？
2. `blkszbits = 12` 意味着块多大？块大小可能是 512 或 8192 吗？依据是什么？
3. 已知 `meta_blkaddr = 0`、`islotbits = 5`，nid 为 200 的 inode 在磁盘哪个字节？
4. 一个 100KB 的文件，datalayout 是 2（FLAT_INLINE）。这可能吗？为什么？
5. `union erofs_inode_i_u` 为什么用 union 而不是四个独立字段？
6. FLAT_PLAIN 与 FLAT_INLINE 的区别到底是什么？
7. CHUNK_BASED 相比 FLAT_PLAIN 的核心优势是什么？用本章的实测数字说明。
8. 看到物理偏移 `17592186040320`，你能立刻反应出它代表什么吗？怎么算的？
9. dirent 为什么设计成定长 12 字节 + `nameoff`，而不是把文件名直接嵌进去？
10. 目录项查找时，为什么 hash 命中后还要做字符串比对？

---

## 自测答案

<details>
<summary>点击展开答案</summary>

**1. 什么位置固定？**

只有 **superblock**（永远在偏移 0）。其余全部由 mkfs 决定。
原因是 EROFS 只读：布局在 mkfs 时定死，运行时不需要增删改，
因此不需要预留空间或可变索引结构，可以自由安排。
官方原话是 "flexible enough for mkfs to play with it"。

**2. blkszbits = 12？块大小能是 512 或 8192 吗？**

`blkszbits = 12` → 块大小 = 1<<12 = **4096 字节**。

- 512（1<<9）：**可以**，`super.c:272` 允许下限为 9
- 8192（1<<13）：**在 4K 页的系统上不行**，因为上限是 `PAGE_SHIFT`（x86_64 上为 12）

注意上限是**页大小**而不是固定值，所以在大页系统（如 arm64 64K 页）上块可以更大。

**3. nid = 200 的 inode 在哪？**

```
偏移 = meta_blkaddr × 块大小 + nid × 槽大小
     = 0 × 4096 + 200 × 32
     = 6400
```

即字节 6400（仍在块 1 内，因为块 1 是 4096~8191）。

**4. 100KB 文件是 FLAT_INLINE，可能吗？**

**完全可能，而且本章就有实测案例**（big.bin）。

因为 FLAT_INLINE 的 "inline" 指的是**尾部**数据内联，不是整个文件内联。
big.bin 的前 98304 字节在独立块，只有最后 1696 字节（不足一块）内联到 inode 后面。

**判断标准是"有没有不足一块的尾巴"，不是"文件大不大"。**

**5. 为什么用 union？**

因为这四种含义**互斥**——一个 inode 只会是其中一种布局。
而 inode 大小直接影响镜像体积（几百万个文件时每字节都很贵），
所以让互斥字段共用 4 个字节是纯收益。

这体现了 EROFS 的核心设计前提：**只读，所以布局定死，所以能压缩到极致。**

**6. FLAT_PLAIN 与 FLAT_INLINE 的区别？**

- **FLAT_PLAIN (0)**：数据全在独立块，没有内联部分
- **FLAT_INLINE (2)**：有独立块存放主体，**外加**尾部不足一块的数据内联在 inode 后

即 FLAT_INLINE = FLAT_PLAIN + tail-packing。

**7. CHUNK_BASED 的核心优势？**

能表达**空洞**（稀疏文件的不占用区域），从而不分配磁盘空间。

本章实测：同一个 1MB 稀疏文件，
FLAT_PLAIN 占 **1052672 字节**，CHUNK_BASED 只占 **69632 字节**，省 93%。

**8. 物理偏移 17592186040320 是什么？**

```
17592186040320 / 4096 = 4294967295 = 0xFFFFFFFF
```

即块号 `0xFFFFFFFF` = `EROFS_NULL_ADDR`（定义为 -1），
表示**这个 chunk 是空洞，没有对应的磁盘块**。

看到超大得离谱的物理偏移，第一反应就应该是"这是 NULL_ADDR / 空洞"。

**9. dirent 为什么定长 + nameoff？**

为了能**二分查找**。

如果文件名嵌在 dirent 里，dirent 就变长，无法用"第 N 项"直接定位，
只能线性遍历。定长之后可以二分，查找从 O(n) 降到 O(log n)。

代价是名字要另外存（从块尾往前排），多一次间接访问——这个取舍是划算的。

**10. 为什么 hash 命中后还要比对字符串？**

因为 **hash 会碰撞**：两个不同的文件名可能算出相同的 hash。

hash 的作用只是**快速缩小候选范围**，
最终必须逐字节比对真实的名字字符串才能确认找到的是不是目标文件。

（这也是所有用 hash 做索引的场景的通则：hash 定位，比对确认。）

</details>


上一章：[00-前置知识-内核存储栈](2026-09-04-erofs-guide.md)

## 参考
