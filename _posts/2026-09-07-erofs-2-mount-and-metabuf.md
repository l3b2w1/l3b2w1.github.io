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

# 阶段 2：挂载与元数据原语

> 本章最重要的内容是 **`erofs_buf` 三件套**。
> 它是 EROFS 取元数据的**唯一**方式——搞懂它，后面每个阶段的代码你都能读懂一大半。

---

## 本阶段目标

读完这一章，你应该能够：

1. 说出挂载从 `mount` 命令到"能访问根目录"经过了哪几步
2. 解释 superblock 校验时"拒绝不兼容特性"的必要性
3. 说出 `sbi` 里 6~8 个关键字段各自"谁会用它"
4. **解释 `erofs_buf` 为什么存在，以及三个函数各自干什么**
5. 能读懂任意一处 `erofs_bread` 调用，并判断什么时候该 `put`
6. 知道 `erofs_buf` 的三个真实隐患（它们都是本项目分析中发现的实际问题）

---

## 2.1 挂载全景

![挂载流程](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-07-erofs-05-mount-flow.svg)

**第一个要注意的点**：现代内核用 **fs_context** 机制挂载，
所以你去找 `erofs_mount()` 是找不到的。入口在这：

```
erofs_fs_type                    super.c   ← 文件系统类型注册
  └─ erofs_init_fs_context       super.c
       └─ erofs_context_ops      super.c
            ├─ .parse_param  →  解析挂载选项（device= / fsoffset= / dax= ...）
            ├─ .get_tree     →  打开块设备，回调 fill_super
            ├─ .reconfigure  →  remount（-o remount,...）
            └─ .free         →  清理
```

真正干活的是 `erofs_fc_fill_super`（`super.c`），它内部的关键步骤：

| 步骤 | 函数 | 干什么 |
|---|---|---|
| ① | `erofs_read_superblock`（`super.c`） | 读 superblock 并校验 |
| ② | — | 填 `sbi`（EROFS 的运行时状态） |
| ③ | `erofs_scan_devices`（`super.c`） | 扫描多设备表（若有） |
| ④ | — | 取 root inode，建立根 dentry |
| ⑤ | — | 处理剩余选项、注册 sysfs |

---

## 2.2 superblock 读取与校验

`erofs_read_superblock`（`super.c`）做的事，一句话：**读进来，然后拼命检查**。

检查项里最重要的是这三类：

#### magic 不匹配 → 拒绝

不是 EROFS 镜像就直接拒绝。这是最基础的保护。

#### 不认识的 incompat 特性 → 拒绝

`feature_incompat` 里任何一个本内核不认识的位，都导致挂载失败。

**为什么这么严格？** 因为"不兼容"意味着磁盘上有本内核读不懂的结构。
硬着头皮读，得到的可能是错误数据，严重的会触发内核异常。

> **宁可拒绝，不可猜。** 这是文件系统设计的通则。

#### 块大小越界 → 拒绝

`super.c` 那个检查：

```c
if (sbi->blkszbits < 9 || sbi->blkszbits > PAGE_SHIFT) {
        erofs_err(sb, "blkszbits %u isn't supported", sbi->blkszbits);
        return -EINVAL;
}
```

块大小必须在 `[512, 页大小]` 之间。超出范围说明镜像损坏或格式不支持。

> 📌 **一个值得记住的背景**：EROFS 官方文档公开声称，
> 内核实现应当"**能够承受任意磁盘损坏而不产生真正有害的行为**"
> （原文："bear any on-disk corruption by design"）。
>
> 换句话说，**EROFS 把"抗恶意镜像"当成自己的设计承诺**。
> 这个承诺在阶段 5 会遇到一个反例——一个由恶意镜像触发的无限自旋缺陷。
> 记住这个对照，到时候你会理解为什么那个缺陷值得上报。

---

## 2.3 `sbi`：EROFS 的运行时状态

`sbi`（`struct erofs_sb_info`，`internal.h`）是 EROFS 挂在 `super_block` 上的私有数据。
字段很多，**现在只需要记住这几个**：

| 字段 | 从哪来 | 谁会用它 |
|---|---|---|
| `blkszbits` | superblock | **到处都在用**。块↔字节换算的基础 |
| `meta_blkaddr` | superblock | `erofs_iloc()` 算 inode 位置（阶段 1 讲过） |
| `islotbits` | `super.c` 由 inode 尺寸算出 | `erofs_iloc()` 的移位量 |
| `packed_nid` | superblock | 找 packed inode（压缩数据/fragment 常放那里，阶段 6） |
| `dif0` | 主设备信息 | **含 `fsoff`**——镜像在设备内的起始偏移 |
| `devs` / `extra_devices` | device table | 多设备支持（阶段 6） |
| `dax_dev`（每设备） | 挂载选项 | FSDAX（阶段 6） |

其中 **`dif0.fsoff` 需要特别留意**，它马上就会在 `erofs_buf` 里反复出现。

`fsoff` 是"镜像在设备内的起始偏移"，由挂载选项 `-o fsoffset=X` 指定，
用于"镜像不放在设备开头"的场景（比如镜像嵌在某个分区的中间）。
绝大多数情况下它是 0。

---

## 2.4 ⭐ `erofs_buf` 三件套

![erofs_buf](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-07-erofs-06-erofs-buf.svg)

#### 它解决什么问题

元数据有三个特点：

1. **经常跨页边界**——一个 inode 可能横跨 4094~4100 字节
2. **读取极其频繁**——每次查找目录、解析 inode 都要读
3. **读的大小都很小**——几个字节到几十字节

如果每次都单独读一页，慢得无法接受。
所以需要一个小游标：读一页，用完不急着还，下次如果还在同一页就直接复用。

这就是 `erofs_buf`。它是 EROFS 取元数据的**唯一**方式——
整个 `fs/erofs/` 里，凡是"从磁盘读一小段元数据"，都走它。

#### ① `erofs_init_metabuf()`（data.c）

决定"去哪个 page cache 取"。

```c
int erofs_init_metabuf(struct erofs_buf *buf, struct super_block *sb,
                       bool in_metabox)
{
        struct erofs_sb_info *sbi = EROFS_SB(sb);

        buf->file = NULL;
        if (in_metabox) {
                if (unlikely(!sbi->metabox_inode))
                        return -EFSCORRUPTED;
                buf->mapping = sbi->metabox_inode->i_mapping;
                return 0;
        }
        buf->off = sbi->dif0.fsoff;              /* ← 注意这里 */
        if (erofs_is_fileio_mode(sbi)) {
                buf->file = sbi->dif0.file;
                buf->mapping = buf->file->f_mapping;
        } else
                buf->mapping = sb->s_bdev->bd_mapping;
        return 0;
}
```

三种 `mapping` 选择（对应阶段 0 讲的 `address_space`）：

| 模式 | `mapping` 指向 | 说明 |
|---|---|---|
| 块设备挂载 | `s_bdev->bd_mapping` | 借块设备自己的 page cache |
| fileio 文件后端 | 后备文件的 `f_mapping` | 借后备文件系统的 page cache |
| metabox | `metabox_inode->i_mapping` | 阶段 6 才讲，先记住有这个分支 |

**重点记住 `buf->off = sbi->dif0.fsoff` 这一行**（data.c）。
它把"镜像在设备内的偏移"记在了 buf 里，后面会引发一个不对称问题。

#### ② `erofs_bread()`（data.c）

取元数据，返回可直接读的指针。

```c
void *erofs_bread(struct erofs_buf *buf, erofs_off_t offset, bool need_kmap)
{
        pgoff_t index = (buf->off + offset) >> PAGE_SHIFT;      /* :31 */
        ...
        if (buf->page) {
                folio = page_folio(buf->page);
                if (folio_file_page(folio, index) != buf->page)  /* :50 */
                        erofs_unmap_metabuf(buf);
        }
        if (!folio || !folio_contains(folio, index)) {           /* :53 */
                erofs_put_metabuf(buf);
                folio = read_mapping_folio(buf->mapping, index, buf->file);
                ...
        }
        buf->page = folio_file_page(folio, index);
        if (!need_kmap)
                return NULL;
        if (!buf->base)
                buf->base = kmap_local_page(buf->page);
        return buf->base + (offset & ~PAGE_MASK);                /* :64 */
}
```

流程是：

1. **算页号**：`index = (buf->off + offset) >> PAGE_SHIFT`（:31）
2. **能复用吗**：看上一页是不是就是这一页（:48-53）
   - 是 → 直接返回，省一次 IO
   - 否 → `put` 旧的，重新 `read_mapping_folio()`（:55）
3. **返回指针**：`buf->base + (offset & ~PAGE_MASK)`（:64）

第 2 步就是"复用"的意义所在：连续读同一页内的多处元数据，只读一次磁盘。

#### ③ `erofs_put_metabuf()`（data.c）

```c
void erofs_put_metabuf(struct erofs_buf *buf)
{
        if (!buf->page)
                return;
        erofs_unmap_metabuf(buf);
        folio_put(page_folio(buf->page));
        buf->page = NULL;
}
```

解除映射 + 释放 folio 引用。**必须调用。**

#### 一次典型的用法

```c
struct erofs_buf buf = {};          /* 通常声明在栈上 */
void *data;

erofs_init_metabuf(&buf, sb, false);
data = erofs_bread(&buf, erofs_iloc(inode), true);
if (IS_ERR(data)) { ... 错误处理 ... }

/* 现在 data 指向 inode 所在位置，可以直接读了 */
parse_inode(data);

erofs_put_metabuf(&buf);            /* ← 别忘了这一步 */
```

**这个模式你会在 EROFS 里看到几十次。** 认熟它。

## 2.5 metabox 初瞥

`erofs_init_metabuf()` 的第一个分支是 metabox（`data.c`）。

它的作用是：nid 的最高位为 1 时，表示该 inode 的元数据存放在 **metabox** 里，
而不是常规的元数据区。此时：

- `erofs_iloc()` 退化成 `nid << islotbits`（不加 `meta_blkaddr`，阶段 1 提过）
- `erofs_init_metabuf()` 用 `metabox_inode->i_mapping`

**为什么需要它？** 服务于**增量构建**——
往已有镜像里追加文件时，不用重排整个元数据区，
把新元数据放进 metabox 即可。

详细内容留到阶段 6。现在只需要知道：**`mapping` 不止一个**


## 术语速查

| 术语 | 含义 | 出处 |
|---|---|---|
| fs_context | 现代内核的统一挂载框架 | 2.1 |
| `erofs_context_ops` | EROFS 的 fs_context 操作集 | `super.c` |
| `erofs_fc_fill_super` | 挂载的实际执行者 | `super.c` |
| `sbi` | EROFS 的运行时状态（`struct erofs_sb_info`） | `internal.h` |
| `fsoff` | 镜像在设备内的起始偏移（`-o fsoffset=`） | `data.c` |
| `erofs_buf` | 取元数据的游标（带单页缓存） | 2.4 |
| metabox | 存放增量构建元数据的特殊区域 | 2.6，详讲见阶段 6 |

## 自测检查点

1. 为什么找不到 `erofs_mount()` 这个函数？
2. `feature_incompat` 里有不认识的位时，内核为什么宁可拒绝挂载也不硬读？
3. `erofs_init_metabuf()` 有哪三种 `mapping` 选择？分别对应什么场景？
4. `erofs_bread()` 的"复用"是怎么判断的？复用的收益是什么？
5. `erofs_bread()` 返回 `NULL` 是错误吗？（提示：看 `need_kmap` 参数）
6. 一个 `erofs_buf` 用完不 `put` 会怎样？
7. 隐患① 的不对称具体在哪两行？`fsoff` 为 0 时会触发吗？
8. 隐患② 为什么叫"跨 mapping 复用"？为什么 metabox 的引入让它成为可能？
9. 为什么 EROFS 敢用"算"来定位 inode（`erofs_iloc`），而不维护索引结构？
10. 读 EROFS 代码时，看到 `erofs_bread` 应该立刻去找什么？

## 自测答案

<details>
<summary>点击展开答案</summary>

**1. 为什么找不到 erofs_mount()？**  

现代内核用 **fs_context** 机制挂载，不再用老的 `->mount` 回调。  
入口是 `erofs_fs_type`（`super.c`）→ `erofs_init_fs_context`（`super.c`）
→ 安装 `erofs_context_ops`（`super.c`），
真正的执行者是 `erofs_fc_fill_super`（`super.c`）。

**2. 为什么不硬读 incompat 特性？**

"不兼容"意味着磁盘上有本内核读不懂的结构。  
硬读会得到错误数据，严重时触发内核异常或安全漏洞。  
文件系统的通则是：**宁可拒绝，不可猜**。

**3. 三种 mapping 选择？**

| 模式 | mapping |
|---|---|
| 块设备挂载 | `sb->s_bdev->bd_mapping` |
| fileio 文件后端 | 后备文件的 `f_mapping` |
| metabox | `sbi->metabox_inode->i_mapping` |

**4. 复用怎么判断？收益？**

判断依据（`data.c`）：上一页的页号是否就是这次要的页号
（用 `folio_file_page(folio, index)` 和 `folio_contains(folio, index)`）。

收益：连续读同一页内的多处元数据时**只读一次磁盘**。  
考虑到读元数据是极高频操作，这个优化很重要。

**5. 返回 NULL 是错误吗？**

**不是。** 看 `data.c`：当 `need_kmap = false` 时，
函数直接 `return NULL`，表示"页已经备好了，但你没要求映射，所以不给你指针"。

错误是通过 `ERR_PTR()` 返回的，要用 `IS_ERR()` 判断，
**不能用 `!ptr` 判断**——这是读这段代码最容易犯的错。

**6. 不 put 会怎样？**

folio 的引用计数不降，页无法回收 → **内存泄漏**。
`erofs_buf` 是栈上的普通结构体，没有析构函数兜底。

**7. 隐患① 的不对称在哪？fsoff=0 会触发吗？**

不对称在 `data.c`（index **加了** `buf->off`）与 `data.c`
（返回指针**没加** `buf->off`）之间。

**`fsoff = 0` 时不会触发**，因为 `+0` 和 `+0` 一样。
只有 `fsoff` 非 0 且不是页大小整数倍时才显现。
（非页对齐的 `fsoffset` 还会被挂载期 superblock 自校验拦下一部分。）

**8. 隐患② 为什么叫"跨 mapping 复用"？**

因为复用判据（`data.c`）只比较**页号**，
从不检查 `buf->mapping` 是否还是同一个。

如果 buf A 用 mapping X 读了第 5 页，
buf B 用 mapping Y 也要读第 5 页，
判据会认为"页号一样，可以复用"，于是返回 X 里的第 5 页——**张冠李戴**。

metabox 的引入让系统里出现了**第二个** `mapping`（之前基本只有块设备一个），
才使这个隐患从"理论上存在"变成"实际可能触发"。
而 metabox 的 `mapping` 偏移从 0 起算，与块设备的低页号区间天然重叠，碰撞概率不为零。

**9. 为什么敢"算"而不维护索引？**

因为 EROFS 是**只读**的：所有布局在 mkfs 时定死，运行时不需要增删改。
不需要插入删除，就不需要 B 树、位图这类可变索引结构。
一次乘法就能定位，这是只读换来的红利。

**10. 看到 erofs_bread 应立刻找什么？**

**找对应的 `erofs_put_metabuf()`。**
这是 `erofs_buf` 的核心契约：取了就必须还，
而且没有语言机制帮你兜底（隐患③）。

读代码时养成这个习惯，你就能自己发现 EROFS 里曾经出现过的那类 bug。

</details>

## 参考
[linux-7.2](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)
