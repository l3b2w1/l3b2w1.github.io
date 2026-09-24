---
layout:     post
title:      EROFS metabox
subtitle:   EROFS 元数据压缩
date:       2026-09-24
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 18 · 特性专题：metabox（元数据压缩）

> 相关源码：`internal.h`（`erofs_inode_in_metabox()`、`erofs_iloc()`）、
> `super.c`（初始化与自检）、`inode.c` / `xattr.c` / `zdata.c`（使用点）
> 关键字段：`metabox_nid`、`nid` 的 `EROFS_DIRENT_NID_METABOX_BIT` 位
>
> 本文回答：**元数据也能压缩吗** → **metabox 是什么** → **怎么标记"在 metabox 里"** →
> **位置计算为什么特殊** → **self-loop 检测在防什么** → **关键结构体与函数**。

## 本专题目标（读完你应该能做到什么）

1. 说清 metabox 解决什么问题（**元数据太多**）
2. 解释 metabox 与常规元数据区的关系
3. 看懂 **nid 的一个 bit** 怎么用来标记"在 metabox 内"
4. 解释 `erofs_iloc()` 在两种情况下的计算差异
5. 说清 **self-loop 检测**为什么必要（防止无限递归）
6. 知道这个标志怎么一路传递到各个读取点

## 图解

![metabox：把元数据也压缩起来](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-24-erofs-37-metabox-design.svg)

**一句话**：文件多了元数据也很大，metabox 就是**装压缩元数据的盒子**——
部分 inode 压缩存进去省空间，代价是读的时候要先解压。

自上而下四层：

| 层 | 回答什么 | 一句话 |
|---|---|---|
| **① 为什么**（淡红） | 元数据也会很大 | 几十万个小文件 ⇒ 元数据可能几十上百 MB；只压数据，省空间打折扣 |
| **② 两块区域**（淡绿） | 元数据存哪 | 常规元数据区（`meta_blkaddr`，**不压缩**，直接读）vs **metabox**（`metabox_nid` 指向，**压缩**，读时解压）；放哪由 mkfs 决定 |
| **③④ 怎么标记 + 怎么定位**（淡蓝 / 淡黄） | 靠什么区分、怎么算位置 | `nid` 的 **bit 63** 当标志位；`erofs_iloc()` 据此选两套算法——**metabox 内不加 `meta_blkaddr`** |
| **⑤⑥ 两个必须注意**（红框 / 淡紫） | 坑在哪 | **self-loop 必须显式禁止**；标志要**一路传递**给每个读元数据的点 |

**三个最容易错的判断：**

1. **metabox 内不加 `meta_blkaddr`** —— metabox 是另一块独立区域（有自己的 `metabox_nid` 与映射），
   不是从 `meta_blkaddr` 开始的，加上反而算错。
2. **self-loop 必须禁止** —— metabox 本身也是个 inode。若它的 nid 自己带了 bit 63，
   就是「metabox 在 metabox 里」⇒ 读 metabox 需要 metabox ⇒ **无限递归**，挂载时直接 `-EFSCORRUPTED`。
3. **标志不是"查一次就扔"** —— `erofs_read_metabuf(&buf, sb, pos, in_metabox)` 的最后一个参数
   要一路传下去（`inode.c` / `xattr.c` / `zdata.c` / `data.c` 都要传），因为每层都可能重新定位。

**动手改图**：源文件 `dot/37-metabox-design.dot`，改完执行

```bash
cd /sdd/erofs/study && dot -Tsvg dot/37-metabox-design.dot -o dot/37-metabox-design.svg
```

## 一、特性缘由：元数据也会很大

#### 1.1 问题：文件多 ⇒ 元数据多

EROFS 压缩的是**文件数据**。但一个镜像里，除了数据还有大量**元数据**：

- 每个文件/目录一个 inode
- 目录项（dirent）
- xattr
- 各种索引

当文件数量极大（比如一个完整发行版的 rootfs，几十万个小文件），
**元数据本身就可能占几十上百 MB**。

⇒ 只压数据不压元数据，省空间的效果打了折扣。

#### 1.2 解决：把元数据也压缩起来

**metabox** 就是"装压缩元数据的盒子"：

```
常规元数据区（meta_blkaddr）  ← 不压缩
metabox                        ← 压缩存放的元数据
```

某些 inode 可以放到 metabox 里，以压缩形式存储。

#### 1.3 代价

读 metabox 里的 inode 需要**先解压**——比常规元数据慢一点。
所以对"冷"的、不常访问的元数据放 metabox 更划算
（具体策略由 mkfs 决定）。

## 二、设计理念

#### 理念 1：用 nid 的一个 bit 做标记

怎么知道某个 inode 在不在 metabox 里？

EROFS 的做法：**在 nid 里占一个位**。

```c
static inline bool erofs_inode_in_metabox(struct inode *inode)
{
        return EROFS_I(inode)->nid & BIT_ULL(EROFS_DIRENT_NID_METABOX_BIT);
}
```

```
nid = [ METABOX 标志位 (1 bit) ][ 实际 nid (其余位) ]
```

**好处**：不需要额外字段——"这个 inode 在哪"的信息
**跟着 nid 一起传递**，任何拿到 nid 的地方都能判断。

**代价**：nid 可用位数少 1 位。

#### 理念 2：位置计算分两套

`erofs_iloc()` 算出 inode 在磁盘上的位置：

```c
static inline erofs_off_t erofs_iloc(struct inode *inode)
{
        struct erofs_sb_info *sbi = EROFS_I_SB(inode);
        erofs_nid_t nid_lo = EROFS_I(inode)->nid & EROFS_DIRENT_NID_MASK;

        if (erofs_inode_in_metabox(inode))
                return nid_lo << sbi->islotbits;              /* ① metabox 内 */
        return erofs_pos(inode->i_sb, sbi->meta_blkaddr) +    /* ② 常规 */
                (nid_lo << sbi->islotbits);
}
```

| 情况 | 计算 |
|---|---|
| **在 metabox 内** | `nid_lo << islotbits` —— **不加 `meta_blkaddr`** |
| **常规** | `meta_blkaddr 转字节 + (nid_lo << islotbits)` |

**为什么 metabox 内不加 `meta_blkaddr`？**

因为 metabox 是**另一块独立的区域**（有自己的 `metabox_nid` 与映射），
不是从 `meta_blkaddr` 开始的。
加上 `meta_blkaddr` 反而会算错。

⇒ 这也是为什么需要理念 1 的标记位——
**不知道"在哪个区域"就没法算出正确位置**。

#### 理念 3：必须防 self-loop

`super.c` 初始化时：

```c
if (erofs_sb_has_metabox(sbi)) {
        ret = -EFSCORRUPTED;
        if (sbi->sb_size <= offsetof(struct erofs_super_block, metabox_nid))
                goto out;
        sbi->metabox_nid = le64_to_cpu(dsb->metabox_nid);
        if (sbi->metabox_nid & BIT_ULL(EROFS_DIRENT_NID_METABOX_BIT))
                goto out;            /* self-loop detection */
}
```

**在防什么**：

metabox 本身也是个 inode（由 `metabox_nid` 指向）。
如果 **metabox 的 nid 自己带了 METABOX 标志位**，
就意味着"metabox 在 metabox 里"——

⇒ 读 metabox 需要 metabox ⇒ **无限递归**。

所以检测到就报错（`-EFSCORRUPTED`）。

这是一个很典型的"**自引用必须显式禁止**"的例子。

#### 理念 4：标志一路传递

看使用点：

```c
erofs_read_metabuf(&buf, sb, pos, erofs_inode_in_metabox(inode));
```

最后那个参数就是"是否在 metabox"标志。
**每个读元数据的地方都要传它**——
因为底层需要知道该用哪套位置计算。

出现位置：

- `inode.c`（读 inode）
- `xattr.c`（读 xattr 头部）
- `zdata.c`（压缩路径读元数据）
- `data.c`（读映射索引）

## 三、实现架构

#### 3.1 对象关系

```
erofs_sb_info
   ├─ meta_blkaddr     ← 常规元数据区起点
   ├─ metabox_nid      ← metabox 这个 inode 的 nid
   └─ metabox_inode    ← 按 metabox_nid igot 出来的 inode

每个 inode 的 nid
   └─ 若 METABOX 位为 1 → 该 inode 在 metabox 内（压缩存放）
```

#### 3.2 读取流程（对比）

```
读一个 inode：
        │
        ├─ erofs_inode_in_metabox(inode)？
        │
   ┌────┴────┐
   ▼         ▼
  是         否
   │         │
   │         └─ erofs_iloc() = meta_blkaddr + nid_lo << islotbits
   │               └─ 直接从元数据区读（未压缩）
   │
   └─ erofs_iloc() = nid_lo << islotbits（不加 meta_blkaddr）
         └─ 通过 metabox_inode 的映射读（压缩，需解压）
```

#### 3.3 标志如何在调用链上传播

```
erofs_iget() / 读 inode
   └─ erofs_iloc()                     判断并算位置
        │
        └─ erofs_read_metabuf(&buf, sb, pos, in_metabox)
                                              ↑
                                        标志一路传下去
```

⇒ **设计要点**：这个标志不是"查一次就扔"，
而是**伴随整个元数据读取过程**，因为每一层都可能要重新定位。

## 四、关键结构体与字段

#### 4.1 `erofs_sb_info`（`internal.h`）

```c
u32 meta_blkaddr;         /* 常规元数据区起始块 */
erofs_nid_t metabox_nid;  /* metabox 的 nid */
struct inode *metabox_inode;   /* metabox 对应的 inode */
```

#### 4.2 `erofs_inode`

```c
erofs_nid_t nid;          /* ★ 最高位（METABOX_BIT）表示在 metabox 内 */
```

**具体是 bit 63**（`EROFS_DIRENT_NID_METABOX_BIT`，见 4.3）。nid 是 `u64`，
所以实际布局是：

```
 bit  63        62                              0
     ┌──┬──────────────────────────────────────┐
     │ M│            实际 nid                   │
     └──┴──────────────────────────────────────┘
      ↑
   METABOX 标志位（1 = 该 inode 在 metabox 内，压缩存放）

 M = 0 → 在常规元数据区（meta_blkaddr），不压缩
 M = 1 → 在 metabox 内，压缩存放，读时需解压
```

⇒ **可用 nid 只有 63 位**（最高位被借走了）。

#### 4.3 相关常量

两个常量都定义在 **`erofs_fs.h`**（不是 `internal.h`），因为它们属于 **on-disk 格式**：

```c
/* fs/erofs/erofs_fs.h:277 */
#define EROFS_DIRENT_NID_METABOX_BIT	63
#define EROFS_DIRENT_NID_MASK	(BIT_ULL(EROFS_DIRENT_NID_METABOX_BIT) - 1)
```

| 常量 | 值 | 含义 |
|---|---|---|
| `EROFS_DIRENT_NID_METABOX_BIT` | **63** | nid 中标记 metabox 的**位号**（即 u64 的最高位） |
| `EROFS_DIRENT_NID_MASK` | `BIT_ULL(63) - 1`<br>= `0x7FFF_FFFF_FFFF_FFFF` | 取 nid 的**有效部分**（低 63 位全 1，去掉标志位） |

用法：

```c
nid & BIT_ULL(EROFS_DIRENT_NID_METABOX_BIT)   /* 是否 metabox（取 bit 63）*/
nid & EROFS_DIRENT_NID_MASK                    /* 实际 nid（低 63 位）*/
```

> ⚠️ **注意 bit 63 这个取值带来的连锁影响**：
>
> 因为标志位在最高位，`nid` 直接当 inode 号用会产生**过大的数字**
> （带 bit 63 的 nid 会是一个接近 2⁶⁴ 的数）。
> 所以还需要 `erofs_nid_to_ino64()` 做移位映射（见 5.3）：
>
> ```c
> return ((nid << 1) & GENMASK_ULL(63, 32)) | (nid & GENMASK(30, 0)) |
> 	((nid >> EROFS_DIRENT_NID_METABOX_BIT) << 31);
> ```
>
> 即把标志位挪到 **bit 31**，避免 inode 号膨胀。
> 注释里也写了"on-disk NIDs remain unchanged"，
> 保证对非 LFS 的 32 位应用仍然兼容。


## 五、主要函数

metabox 的内核改动很小，全部集中在**三个 inline 函数 + 一处 buf 初始化**上。
按调用频率从高到低讲。

#### 5.1 `erofs_inode_in_metabox()`（`internal.h`）

```c
static inline bool erofs_inode_in_metabox(struct inode *inode)
{
        return EROFS_I(inode)->nid & BIT_ULL(EROFS_DIRENT_NID_METABOX_BIT);
}
```

配套的常量在 `erofs_fs.h`：

```c
#define EROFS_DIRENT_NID_METABOX_BIT    63
#define EROFS_DIRENT_NID_MASK           (BIT_ULL(EROFS_DIRENT_NID_METABOX_BIT) - 1)
```

⇒ 判断的就是 **nid 的第 63 位**（最高位）。`EROFS_DIRENT_NID_MASK` 是低 63 位的掩码，
用来把标志位剔掉、取回真正的 nid 数值（下一节的 `erofs_iloc()` 就用它）。

**这是全专题最高频的一个判断**——每次读元数据都要问一次，
因为答案决定了"这次要用哪一套地址空间去读"（见 5.4）。

#### 5.2 `erofs_iloc()`（`internal.h`）—— 两套位置计算

这是 metabox 最核心的一段：**同一个 inode，位置怎么算，取决于它在不在 metabox 里**。

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

拆开看：

1. `nid_lo = nid & EROFS_DIRENT_NID_MASK` —— 先**去掉第 63 位的标志**，得到纯 nid
2. `nid_lo << sbi->islotbits` —— nid 乘以 inode slot 大小（`islotbits` 通常为 5，即 32 字节/inode），
   得到**相对于某个起点的偏移**
3. 关键在"加上什么作为起点"：

| 情况 | 返回值 | 含义 |
|---|---|---|
| **在 metabox 内** | `nid_lo << islotbits` | 偏移是**相对 metabox 自己**的，不加 `meta_blkaddr` |
| 普通 inode | `erofs_pos(sb, meta_blkaddr) + (nid_lo << islotbits)` | 偏移是相对**整个元数据区起点**的 |

`erofs_pos()` 就是 `internal.h` 里那个块→字节的换算宏（`blk << s_blocksize_bits`）。

⇒ 一句话记住：**metabox 内的 inode 用的是"箱内相对地址"，所以不要再加 `meta_blkaddr`**。
这也是"误解 3"要纠正的点。

#### 5.3 `erofs_nid_to_ino64()`（`internal.h`）—— inode 号的映射

```c
static inline u64 erofs_nid_to_ino64(struct erofs_sb_info *sbi, erofs_nid_t nid)
{
        if (!erofs_sb_has_metabox(sbi))
                return nid;

        /*
         * When metadata compression is enabled, avoid generating excessively
         * large inode numbers for metadata-compressed inodes.  Shift NIDs in
         * the 31-62 bit range left by one and move the metabox flag to bit 31.
         *
         * Note: on-disk NIDs remain unchanged as they are primarily used for
         * compatibility with non-LFS 32-bit applications.
         */
        return ((nid << 1) & GENMASK_ULL(63, 32)) | (nid & GENMASK(30, 0)) |
                ((nid >> EROFS_DIRENT_NID_METABOX_BIT) << 31);
}
```

**为什么要多这一步？**

不启用 metabox 时，nid 直接当 inode 号用。启用后 nid 的最高位（bit 63）被借去当标志位，
若还直接当 inode 号，数值就会大到 2^63 量级——**超过很多用户态程序能处理的范围**
（尤其是没开 LFS 的 32 位应用）。

所以这个函数做一次重排位：

- `(nid << 1) & GENMASK_ULL(63, 32)` —— 把 31~62 这段**整体左移一位**，腾出 bit 31
- `(nid & GENMASK(30, 0))` —— 低 31 位（0~30）**原样保留**（保证小 nid 的 inode 号不变，兼容 32 位应用）
- `((nid >> EROFS_DIRENT_NID_METABOX_BIT) << 31)` —— 把原来 bit 63 的标志**挪到 bit 31**

⇒ 注释里那句很重要：**on-disk 的 nid 没变**——这只影响内核给 VFS 看的 `i_ino`，
磁盘格式完全不动。

⇒ 这也说明 metabox 的影响**不止在读路径**，还波及 inode 号的生成。

#### 5.4 `erofs_init_metabuf()` / `erofs_read_metabuf()`（`data.c`）—— 决定"从哪读"

这是把 5.1 的判断落到实处的那一层：**元数据到底从哪个 address_space 读**。

```c
int erofs_init_metabuf(struct erofs_buf *buf, struct super_block *sb,
                       bool in_metabox)
{
        struct erofs_sb_info *sbi = EROFS_SB(sb);

        buf->mc = false;
        if (in_metabox) {
                if (unlikely(!sbi->metabox_inode))
                        return -EFSCORRUPTED;
                buf->mapping = sbi->metabox_inode->i_mapping;
                return 0;
        }
        if (erofs_is_fileio_mode(sbi)) {
                buf->mapping = sbi->managed_cache->i_mapping;
                buf->mc = true;
        } else {
                buf->off = sbi->dif0.fsoff;
                buf->mapping = sb->s_bdev->bd_mapping;
        }
        return 0;
}

void *erofs_read_metabuf(struct erofs_buf *buf, struct super_block *sb,
                         erofs_off_t offset, bool in_metabox)
{
        int err;

        err = erofs_init_metabuf(buf, sb, in_metabox);
        if (err)
                return ERR_PTR(err);
        return erofs_bread(buf, offset, true);
}
```

三条路，对应三种元数据来源：

| 分支 | `buf->mapping` | 说明 |
|---|---|---|
| **metabox** | `sbi->metabox_inode->i_mapping` | 走 metabox 那个"假 inode"的地址空间。
  读它时会触发解压——这正是"元数据压缩"的实现方式：
  元数据被当成一份压缩文件存着，读的时候按需解压
| fileio 模式 | `sbi->managed_cache->i_mapping`，`mc = true` | 镜像是文件后端时，走 managed cache
| 普通块设备 | `sb->s_bdev->bd_mapping`，`off = sbi->dif0.fsoff` | 直接读块设备，`off` 记上 fsoffset

两个容易忽略的点：

1. `buf->off` 只在**非 metabox** 分支被设置（= `dif0.fsoff`）。
   metabox 分支直接返回，`buf->off` 保持 `__EROFS_BUF_INITIALIZER` 给的 0
   ⇒ 又一次体现"metabox 内是另一套坐标系"
2. `sbi->metabox_inode` 为空时返回 **`-EFSCORRUPTED`**（镜像坏了）。
   因为 nid 的标志位说"我在 metabox 里"，但 superblock 根本没建 metabox inode——自相矛盾

#### 5.5 使用点（标志一路传下去）

| 位置 | 用途 |
|---|---|
| `inode.c` | 读 inode 本体：`bool in_mbox = erofs_inode_in_metabox(inode)`，
  传给 `erofs_read_metabuf()`；同时用 `erofs_iloc(inode)` 算 blkaddr/of |
| `xattr.c` | 读 xattr 头部与 shared xattr，`erofs_iloc(inode) + vi->inode_isize` 后同样要传标志 |
| `zdata.c` | 压缩路径读元数据（把 `erofs_inode_in_metabox(fe->inode)` 传给 metabuf） |
| `data.c` | 读映射索引；`erofs_init_metabuf()` / `erofs_read_metabuf()` 就定义在这里 |
| `zmap.c` | 把 `erofs_inode_in_metabox(inode)` 存进 `m.in_mbox`，随映射结果往下传 |
| `fileio.c` | 文件后端路径读元数据时也要带上标志 |

⇒ 可以看到同一个模式：**先 `erofs_iloc()` 算位置，再把 `erofs_inode_in_metabox()` 的结果
当作参数传给 `erofs_read_metabuf()`**。两个函数几乎总是成对出现。
## 六、来龙去脉：完整串一遍

```
① mkfs 阶段
     ├ 把一部分 inode（通常是"冷"的）压缩
     ├ 存进 metabox
     ├ 这些 inode 的 nid 打上 METABOX 标志位
     └ 把 metabox 自身的 nid 写进 superblock（不带标志位！）
        │
② 挂载
     ├ erofs_sb_has_metabox()？
     ├ 读 metabox_nid
     ├ ★ self-loop 检测：metabox_nid 带标志位 → -EFSCORRUPTED
     └ igot 出 metabox_inode
        │
③ 读某个文件
     └ erofs_iget(sb, nid)
        │
④ erofs_inode_in_metabox(inode)？
        ├ 否 → 位置 = meta_blkaddr + nid_lo << islotbits，直接读
        └ 是 → 位置 = nid_lo << islotbits，走 metabox_inode 的映射（解压）
        │
⑤ erofs_read_metabuf(..., in_metabox)  ← 标志传下去
        │
⑥ 拿到 inode 数据
```

## 七、动手验证

#### 验证 1：确认特性定义与自检

```bash
cd /sdd/linux/linux-stable/fs/erofs
grep -rn "metabox" .
```

重点看：
- `internal.h` 的 `erofs_inode_in_metabox()` 与 `erofs_iloc()`
- `super.c` 里的 self-loop 检测那几行

#### 验证 2：确认两套位置计算的差异

```bash
cd /sdd/linux/linux-stable/fs/erofs
grep -n -A8 "static inline erofs_off_t erofs_iloc" internal.h
```

对照 `if (erofs_inode_in_metabox(inode))` 分支与 else 分支，
确认**一个加 `meta_blkaddr`、一个不加**。

#### 验证 3：看标志位怎么传递

```bash
grep -rn "erofs_inode_in_metabox" /sdd/linux/linux-stable/fs/erofs/*.c
```

看它出现在哪些 `erofs_read_metabuf()` 调用里——
体会"标志伴随整个读取过程"这一点。

#### 验证 4：确认镜像是否启用

```bash
/opt/erofs-utils/bin/dump.erofs -s /tmp/erofs-lab/comp2.erofs
```

看 superblock 的 feature 位 / metabox 相关信息。

## 八、常见误解（重要）

#### 误解 1：metabox 是"另一种元数据区"，只是位置不同

不只是位置不同——**metabox 里的元数据是压缩存放的**，
读取需要解压。所以它同时影响：

- 位置计算（`erofs_iloc`）
- 读取方式（要解压）
- inode 号生成（`erofs_nid_to_ino64`）

#### 误解 2：`nid` 就是 inode 编号，不含其他信息

启用 metabox 时，**nid 最高位被借去当标志位**了。
用 `nid` 前要注意是否该 `& EROFS_DIRENT_NID_MASK`。

#### 误解 3：metabox 内的位置也要加 `meta_blkaddr`

**不要**。metabox 是独立区域，
`erofs_iloc()` 里 metabox 分支**故意不加** `meta_blkaddr`。
加了反而算错。

#### 误解 4：self-loop 检测是多余的检查

不是。如果 `metabox_nid` 自己带 METABOX 标志位，
意味着"读 metabox 要先读 metabox"——**无限递归**。
必须显式拦住。

#### 误解 5：metabox 只影响读 inode

不止。它还影响 **inode 号的生成**（`erofs_nid_to_ino64` 要移位），
以及每个读元数据的调用点（都要传标志）。

## 九、与其他特性的关系

| 特性 | 关系 |
|---|---|
| **xattr**（12 专题） | shared xattr 也可放 metabox（`erofs_sb_has_shared_ea_in_metabox()`） |
| **压缩**（04） | 压缩路径读元数据也要判断 metabox（`zdata.c`） |
| **on-disk 格式**（01） | nid / meta_blkaddr 概念的延伸 |
| **ishare**（11） | 无关——metabox 管元数据存放，ishare 管页缓存共享 |

## 自测检查点

1. metabox 解决什么问题？
2. 怎么标记一个 inode "在 metabox 内"？代价是什么？
3. `erofs_iloc()` 在 metabox 内外的计算有什么不同？为什么？
4. self-loop 检测在防什么？不检测会怎样？
5. `EROSF_DIRENT_NID_MASK` 的作用？
6. 这个标志在调用链上是怎么传播的？举两个使用点。
7. metabox 里的元数据是压缩的吗？
8. `erofs_nid_to_ino64()` 为什么要在启用 metabox 时特殊处理？
9. `metabox_nid` 自己能不能带 METABOX 标志位？
10. metabox 除了读路径，还影响了什么？

## 自测答案

<details>
<summary>点击展开</summary>

1. 元数据（inode / dirent / xattr / 索引）**本身也很大**，
   只压数据不压元数据，省空间效果打折。metabox 用来**压缩存放元数据**。

2. 用 **nid 的一个 bit**（`EROFS_DIRENT_NID_METABOX_BIT`）。
   代价：nid 可用位数少 1 位。

3. **metabox 内**：`nid_lo << islotbits`，**不加 `meta_blkaddr`**；
   **常规**：`erofs_pos(sb, meta_blkaddr) + (nid_lo << islotbits)`。
   因为 metabox 是独立区域，不是从 `meta_blkaddr` 开始的，加上反而算错。

4. 防"**metabox 在 metabox 里**"。
   那样读 metabox 需要先读 metabox ⇒ **无限递归**。
   不检测会导致启动即死循环/栈溢出。

5. 取 nid 的**有效部分**（屏蔽掉 METABOX 标志位），
   得到真正的 nid 用于位置计算。

6. 作为**参数传给每次元数据读取**。例如
   `erofs_read_metabuf(&buf, sb, pos, erofs_inode_in_metabox(inode))`——
   出现在 `inode.c`、`xattr.c`、`zdata.c`、`data.c` 的读取点。

7. **是**。metabox 里的元数据以压缩形式存放，读取需要解压
   （这也是为什么它适合放"冷"元数据）。

8. 因为启用 metabox 后 nid 多占了一个标志位，
   直接当 inode 号会产生**过大的数字**。
   该函数做移位/映射避免 inode 号膨胀。

9. **不能**。若带了该位，说明 metabox 自引用，
   `super.c` 会检测并报错 `-EFSCORRUPTED`。

10. 还影响 **inode 号的生成**（`erofs_nid_to_ino64()` 需特殊处理），
    以及**每个读元数据的调用点**（都要传标志）。

</details>

## 参考
[linux-stable](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)
