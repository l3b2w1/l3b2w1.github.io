---
layout:     post
title:      EROFS Prerequisites
subtitle:   EROFS 前置知识
date:       2026-09-03
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 阶段 0：内核存储栈前置

> 这一章不出现任何 EROFS 代码。
> 但如果你跳过它，后面每一章你都会觉得"这句话在说什么"。


## 本阶段目标

读完这一章，你应该能够：

1. 说出一次 `read()` 从用户程序到硬件经过哪几层，每层负责回答什么问题
2. 说清 `super_block` / `inode` / `dentry` / `file` 四个对象各自代表什么
3. 解释 page cache 为什么存在，以及 `address_space` 和 folio 分别是什么
4. 区分扇区（sector）、块（block）、页（page）三个单位，知道它们的典型取值
5. 说清 iomap 是干什么的、它替代了什么
6. 说清"只读"和"压缩"这两个属性，各自给文件系统带来了什么额外负担

## 前置要求

- 会 C 语言（能看懂结构体、函数指针、位运算）
- 会在 Linux 命令行下工作
- 知道"文件系统"是个什么概念（能存文件、有目录树的那种东西）

不需要任何内核知识。本章就是把这些知识补上。

## 0.1 为什么需要这一章

大多数 EROFS 入门材料的写法是：先讲 on-disk 格式（superblock 长什么样、inode 怎么存），
然后开始贴源码。

问题在于：**EROFS 的代码不是独立存在的，它是嵌在内核存储栈里的。**
打开 `fs/erofs/data.c`，会看到它在调用 `iomap`、在操作 folio、在和 VFS 的 `address_space` 打交道。  
这些都不是 EROFS 的东西，是内核公共设施。  


EROFS 本身的代码量相当精简——它的核心实现只有二十来个源文件，规模远小于常见的通用读写文件系统。

> 📌 **EROFS 很精简，因为大量复杂工作由 VFS、内存管理、iomap、block layer
> 这些内核公共设施承担，文件系统只需实现自己特有的那部分——on-disk 布局、inode / 目录、
> 逻辑范围到存储布局的映射，以及压缩数据的获取与解压。**


## 0.2 一次 read() 的旅程

先看全景。假设你执行了：

```c
int fd = open("/mnt/erofs/hello.txt", O_RDONLY);
read(fd, buf, 4096);
```

![read 调用链](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-04-erofs-01-read-syscall-flow.svg)

图上最重要的一条线是**绿色的那条**：如果数据已经在内存里（page cache 命中），
请求**根本不会到磁盘**。大部分日常读操作都走这条路。

这条线为什么重要？因为它决定了文件系统代码的形态。  
EROFS 的代码不是在"每次读的时候去磁盘拿数据"，而是在"缓存没有的时候，告诉内核去哪里拿"。
这个区别一开始不明显，到阶段 3 你会越来越清楚。


## 0.3 五个层次

![存储栈](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-04-erofs-00-storage-stack.svg)

每一层回答一个不同的问题：

| 层次 | 回答的问题 | 是否 EROFS 的代码 |
|---|---|---|
| 系统调用入口 | 参数合法吗？fd 存在吗？ | 否，内核通用 |
| VFS | 不管什么文件系统，统一怎么调用？ | 否，内核通用 |
| page cache | 数据在内存里了吗？ | 否，内核通用（但 EROFS 要会用） |
| **具体文件系统** | **这段数据在磁盘哪里？** | **是，EROFS 全部代码在这** |
| block layer + 驱动 | 怎么把请求交给硬件？ | 否，内核通用 |

**为了理解读路径，可以先把 EROFS 抽象成一句话**：它负责把"文件的逻辑范围"映射到
"EROFS 的存储布局"，并在压缩情况下完成相应的数据获取与解压。其余脏活——真正读磁盘由
block layer 做，缓存由 page cache 做，接口统一由 VFS 做——都不归它管。

⚠️ **但别把这个抽象当成 EROFS 的全部职责。** 它真实负责的东西要多得多，例如：

- superblock 的解析与校验、挂载 / 卸载逻辑
- inode 与目录的解析
- xattr 与 ACL
- **tail-packing**（把尾部数据塞进 inode 后面，避免浪费整块）
- 压缩数据的映射、pcluster 管理与解压调度
- fragment / 去重相关元数据
- 多设备（设备表、外部 blob）
- 文件后端（file-backed image）、FSDAX、page-cache sharing 等可选特性

**⇒ 所以 EROFS 代码少，不是因为它"只做一件事"，而是因为上述每一项都建立在内核公共设施之上：**
没有日志与分配器（不可变）、没有自己的缓存层（用 page cache）、没有重复的 I/O 流程（用 iomap）。


## 0.4 VFS 的四个对象

VFS（Virtual File System，虚拟文件系统）是内核的一层抽象，
它让 `read()` 这类系统调用不需要知道底层是 ext4 还是 EROFS。

它靠四个核心对象做到这一点：

| 对象 | 代表什么 | 一句话理解 |
|---|---|---|
| `struct super_block` | 一个**已挂载的文件系统实例** | "这一整个挂载起来的文件系统" |
| `struct inode` | 一个**文件**（或目录）的元数据 | "这个文件本身"（不含文件名） |
| `struct dentry` | 一个**目录项**，即路径中的一个名字 | "这个名字指向哪个 inode" |
| `struct file` | 一个**被进程打开的文件** | "某个进程正在用这个文件" |

这里最反直觉的是 **`inode` 和 `dentry` 是分开的**：

- `inode` 是文件本体（大小、权限、数据在哪）
- `dentry` 是"名字 → inode"的映射

为什么要分开？因为**一个文件可以有多个名字**（硬链接）。
`/a.txt` 和 `/b.txt` 可以指向同一个 inode。
如果名字存在 inode 里，就没法表达这种关系。

> **这对 EROFS 有个直接影响**：EROFS 的 on-disk 格式里，inode 是**不带文件名**的。
> 文件名存在目录文件（dirent）里，靠 nid（inode 编号）索引。
> 这在阶段 1 会看到。

第四个对象 `struct file` 容易被忽略，但它很重要：  
它代表"**一次打开**"。同一个文件被两个进程打开，就有两个 `struct file`，
但它们指向同一个 `inode`。`file` 里存着读写位置（文件偏移量）这类"会话状态"。

## 0.5 page cache：为什么它是核心

### 它解决什么问题

磁盘很慢，内存很快。同一个文件反复读，每次都去磁盘是不可接受的。
所以内核在内存里留了一块区域缓存文件数据，叫 **page cache**。

**几乎所有文件读操作最终都是在和 page cache 打交道**，而不是直接和磁盘打交道。

### `address_space`：page cache 的管理器

每个 `inode` 有一个**专属的 page cache**，管理它的结构体叫 `struct address_space`。

```c
struct inode {
    ...
    struct address_space *i_mapping;   /* 这个文件的 page cache */
    ...
};
```

注意一个容易混淆的点：**`address_space` 不是"地址空间"这个笼统概念**，
它就是 **"一个 inode 的页缓存的管理器"**。它里面存着：

- 这个文件的页缓存里有哪些页（一棵 radix/xarray 树）
- 怎么去磁盘取一页（一组操作函数）
- 各种统计与标志

> 在 EROFS 里你会反复看到 `inode->i_mapping` 和 `buf->mapping`。
> 记住：**`mapping` 就是"这块数据属于哪个文件的缓存"的身份证**。  
>
> 这个身份证在阶段 2 会变成一个关键问题：EROFS 缓存元数据时会借用一个**假的** inode，
> 如果搞混了两个 `mapping`，就会读到错误的数据。

### folio：页的容器

内核管理内存的基本单位是**页**（通常 4096 字节）。
历史上用 `struct page` 表示一页。但从 Linux 5.16 起，内核引入了 **folio**：

> **folio** 是"一个或多个**物理连续**的页"的容器，现代内核用它替代 `struct page`
> 作为操作页缓存的主要句柄。

为什么要引入它？因为一个 `struct page` 只代表一页，
而内核里很多地方其实在操作"一组连续的页"（比如一次读 64KB）。  
用 `struct page` 表达"这是连续 16 页中的第 3 页"很容易出错——
你拿到一个 `struct page`，不知道它是单独一页还是大块内存的一部分。

folio 把这个歧义消除了：一个 folio 明确知道自己有多大（order）。

**对于读 EROFS 代码的影响**：

- 看到 `folio` 就当"一页（或连续几页）内存"理解，不会错
- 看到 `page_folio(page)` 是把旧式的 `page` 转成 folio
- 看到 `folio_contains(folio, index)` 是在问"这个页号在这个 folio 里吗"

> ⚠️ **不要假定 folio 一定是单页（order = 0）。** 大页（large folio）支持在内核中持续演进，
> EROFS 也已经有了 large folio 相关支持。读代码时正确的做法是**看具体路径怎么处理**，
> 而不是预设 `folio_order(folio) == 0`。凡是看到直接按单页假设写的代码，都应先确认它是否
> 用了 `folio_size()` / `folio_nr_pages()` 之类的接口来表达大小——那才是版本无关的正确写法。

### 为什么文件系统必须关心这些

因为**文件系统要把磁盘数据填进 page cache**，这项工作没人替它做。

具体说，当缓存未命中时，内核会：

1. 分配一个 folio（空的内存页）
2. 问文件系统："文件第 N 页，在磁盘的哪个块？"
3. 拿着块地址去 block layer 读
4. 数据填进 folio，标记为"已是最新"（uptodate）
5. 拷贝给用户

**第 2 步就是文件系统的工作**——这正是 EROFS 的 `erofs_map_blocks` 做的事。这个"问地址"的动作在 EROFS 里被拆成了非压缩和压缩两套完全不同的逻辑。

## 0.6 扇区、块、页：三个容易混淆的单位

内核里有几个"大小"概念，单位不同，混用会让人抓狂：

| 概念 | 典型值 | 谁在用 | 说明 |
|---|---|---|---|
| **扇区 sector** | 512 字节 | block layer | **Linux block layer 传统的块设备寻址 / IO 粒度单位**，历史上通常为 512 字节。<br>⚠️ 它**不等同于**"磁盘硬件的最小传输单位"：现代设备有 4Kn、512e 等形态，设备的 **logical / physical block size 不一定是 512 字节**。 |
| **文件系统块 block** | 4096 字节 | 文件系统 | EROFS 的分配与映射单位。见下方说明——它**不是**编译期常量，也**不是** `PAGE_SIZE`。 |
| **页 / folio** | 4096 字节（架构相关） | 内存管理 / page cache | 内存管理与 page cache 的缓存单位。 |

### ⚠️ 特别要分清三个 size

这是读 EROFS 时最容易混淆的地方，请务必分开：

| 名称 | 是什么 | 由谁决定 |
|---|---|---|
| **`PAGE_SIZE`** | 内核内存管理 / page cache 的页大小 | **内核配置与架构**（x86_64 通常 4K，arm64 可能是 4K / 16K / 64K） |
| **filesystem block size** | EROFS 自己的分配与映射单位 | **镜像本身**（superblock 的 `blkszbits` 字段），`mkfs.erofs -b` 可指定，默认取系统 page size |
| **pcluster size** | 压缩数据的物理簇大小 | **压缩布局**（阶段 4），与上面两个都不是一回事 |

⇒ **filesystem block size 与 `PAGE_SIZE` 是两个独立概念。** 二者相等时很多代码路径可以简化，
但 EROFS 允许 block size 小于 page size（所谓 **sub-page blocksize**），那时会出现"一个页里有多个块"的情况，
也就有了不少额外的边界处理（阶段 3、4 会反复遇到）。

### EROFS 的块大小如何确定

它**不是**编译期常量，而是存在 superblock 的 `blkszbits` 字段里。EROFS 在挂载时（`super.c` 负责读入并校验合法范围）：

```c
sbi->blkszbits = dsb->blkszbits;                                  /* super.c */
if (sbi->blkszbits < 9 || sbi->blkszbits > PAGE_SHIFT) { 
        erofs_err(sb, "blkszbits %u isn't supported", sbi->blkszbits);
```

即块大小可以是 **512 字节（1<<9）到页大小（1<<PAGE_SHIFT）之间的任意 2 的幂**。  

`mkfs.erofs` 默认用 4096，所以你实际见到的镜像基本都是 4096 字节块——
**但这不是硬性规定**。

页大小在 x86_64 上通常也是 4096，但在 arm64 上可能是 4096 / 16384 / 65536。

**块和页不一样大时会怎样？** 这是 EROFS 的一个坑：

- 页 4096、块 4096：一一对应，最简单
- 页 65536、块 4096：一页能装 16 个块（叫 sub-page blocksize 场景）

EROFS 声称支持后者，但代码里有若干处处理得不够干净。
阶段 3 你会看到一个相关的遗留疑问。**现在只要记住：块大小 ≠ 页大小是可能的。**

### 为什么到处都是位运算

你会看到 `blkszbits`、`s_blocksize - 1`、`>> PAGE_SHIFT` 这类写法。原因有两个：

1. **除法慢，移位快**。内核热路径上能省则省。`addr >> blkszbits` 就是 `addr / blocksize`。
2. **掩码取余**。`off & (blocksize - 1)` 就是 `off % blocksize`
   （只在 blocksize 是 2 的幂时成立，而它确实是）。

所以看到 `erofs_blkoff(sb, addr)`，它做的就是 `addr & (blocksize - 1)`，
即"这个地址在块内的偏移"。

## 0.7 iomap：现代内核的映射接口

### 它是什么

iomap 是内核提供的一套**通用 I/O mapping 框架**。它的核心是让文件系统描述
"文件的这段逻辑范围，对应后端存储的哪个物理范围"；在此之上，框架再把
**buffered I/O、direct I/O、DAX、readahead** 等一系列 I/O 路径中的公共流程抽象出来。

一句话：**iomap 是 VFS 与文件系统之间关于"地址翻译"的标准协议。**

### 它替代了什么

老的接口是这样工作的：文件系统实现 `->readpage()`，
内核说"给我读第 5 页"，文件系统自己去查地址、提交 IO、等待完成。  
每件事都得文件系统自己干一遍，ext4、XFS、btrfs 各写各的，大量重复。

iomap 的做法是：文件系统**主要**实现"翻译"这一件事——
"文件偏移 20K~24K 对应磁盘块 1000~1001"；
至于怎么提交 IO、怎么处理 DAX，则由 iomap 框架用公共代码完成。

> ⚠️ **但"全部由框架处理"是过度简化。** 例如 **FIEMAP**：文件系统仍然需要以自己的
> `iomap_ops` 提供正确的 mapping 信息（EROFS 里就是 `erofs_iomap_ops` 被
> `iomap_fiemap()` 回调），框架只是负责遍历与填充结果，并不替文件系统"知道"数据在哪。
>
> 更准确的说法是：**文件系统提供 mapping，iomap 框架复用这套 mapping 去驱动多种 I/O 路径。**

```
      文件偏移                   磁盘位置
   [0K  ───  4K]    ──→     块 100
   [4K  ───  8K]    ──→     块 101
   [8K  ─── 12K]    ──→     HOLE（空洞，没有对应块）
```

### 为什么 EROFS 用 iomap

**EROFS 现在的非压缩读路径全部走 iomap。**

这意味着你在 `fs/erofs/data.c` 里看到的是 `erofs_iomap_ops` 这样的结构，
而不是 `->readpage`。  
如果你按老教程去找 `erofs_readpage`，
会找不到——不是你漏了，是接口换了（VFS 现在以 `read_folio` / `readahead` 为核心，而非旧式的 `readpage` 模型）。

对读者的实际影响：

- 读 EROFS 代码时，**先找 iomap 相关的函数**（`erofs_iomap_begin` 之类）
- 理解"映射"是核心动作，`struct iomap` 是核心数据结构
- 阶段 3 会详细走一遍


## 0.8 只读 + 压缩：EROFS 的两重特殊性

前面讲的所有内容，对 ext4 也适用。现在讲 EROFS 特有的两件事。

### 只读意味着什么

EROFS 是 **Read-Only File System**——更准确地说，它是一个**不可变（immutable）镜像文件系统**：
镜像本身挂载后不可写。

这带来几个简化：

- 不需要分配器（不用管"新数据放哪"）
- 不需要日志（不用管崩溃恢复）
- 不需要写路径的锁

但也带来一个**约束**：所有数据布局在 `mkfs` 时就定死了。
运行时只能"按图索骥"，不能调整。  
所以 **on-disk 格式的设计自由度全在 mkfs 那边**——
这也解释了为什么 EROFS 有 **5 种 datalayout**（阶段 1）：
mkfs 根据文件特点挑一种最合适的布局写死。

5 种 datalayout 具体是（名字先混个眼熟，阶段 1 详讲）：

| 名称 | 用途 |
|---|---|
| `EROFS_INODE_FLAT_PLAIN` | 非压缩，数据在独立块 |
| `EROFS_INODE_FLAT_INLINE` | 非压缩 + **尾部数据内联**（tail-packing） |
| `EROFS_INODE_CHUNK_BASED` | 按固定大小分块（可表达空洞，用于稀疏文件 / 去重） |
| `EROFS_INODE_COMPRESSED_FULL` | 压缩，索引用完整格式 |
| `EROFS_INODE_COMPRESSED_COMPACT` | 压缩，索引用紧凑格式 |

> ⚠️ 注意别把三件事混为一谈：**inode 的布局**（字段怎么排）、**data 的布局**（数据放哪，即上表）、
> 以及**压缩布局**（pcluster 怎么组织）。上表说的是 **data layout**。

> 💡 **"只读"不等于"用户看到的系统不可写"。** 实际部署中，EROFS 作为不可变底座，
> 上层常配合 **OverlayFS** 使用：把用户的写入重定向到另一个可写文件系统，
> 于是用户看到的是"可写的系统"，而底层的 EROFS 镜像始终不变。
> 这也是容器 / 桌面场景的常见用法——理解这点有助于明白 EROFS 为什么可以不做写路径。

### 压缩带来的额外负担

压缩是 EROFS 的**可选**特性，但它是 EROFS 复杂性的主要来源。

非压缩文件系统回答"文件偏移 8000，在磁盘哪里"是个简单算术。
压缩文件系统不行，因为：

1. **需要先查索引**：数据在磁盘上是压缩的，压缩后长度不定，
   没法用"偏移 ÷ 块大小"算出来，必须查索引
   （索引本身也是元数据，**很可能已经在 page cache 里**，不一定每次都产生一次独立的 IO）
2. **解压单位和页不对齐**：压缩是以"pcluster"（物理压缩簇）为单位进行的，
   一个 pcluster 解压出来的数据可能跨越几个页，也可能一个页只需要其中的一部分
3. **要现场解压**：读到的数据不能直接给用户，得先解压到内存
4. **解压结果要复用**：同一个 pcluster 可能同时被多个读请求需要，
   不能各解各的（浪费 CPU），所以要有协调机制

第 4 点是理解 EROFS 压缩路径的关键，也是阶段 4 最难的部分。

**现在你只需要建立一个直觉：对压缩过的 inode 而言，一次读不再是"算个地址就直接读"，
而要额外经过 "映射 → 获取压缩簇 → 解压 → 提供结果" 这些步骤。**

### ⚠️ 别急着把 EROFS 等同于"压缩文件系统"

读到这里，你很容易形成一个印象：

```
EROFS = 只读 + 压缩
```

**这个印象是片面的，而且会阻碍后面理解很多设计。** 正确的定位是：

```
EROFS = 不可变（immutable）的块设备文件系统
      + 高效的 on-disk 布局（低元数据冗余、无集中式 inode/dir 表）
      + 【可选】压缩
      + 【可选】高级特性（chunk 去重 / 多设备 / FSDAX / page-cache sharing / 文件后端 …）
```

几个要点：

- **压缩是可选特性。** `mkfs.erofs` 默认产出的是**不压缩**的 plain 镜像（除非你显式指定 `-z`）。
- EROFS 的官方定位是"modern / general-purpose / high-performance **immutable** filesystem"，
  压缩只是它的能力之一。
- 核心 on-disk 格式其实很朴素：主要由 **superblock + inode + directory entry** 三者构成；
  压缩、chunk、xattr 等都是在这个核心之上**可选启用**的扩展。

⇒ **先按"一个精简的不可变文件系统"去理解 EROFS，再把压缩当作叠加在其上的一层。**
这个顺序会让你在阶段 1（on-disk 格式）和阶段 4（压缩）都轻松很多。

## 术语速查

| 术语 | 含义 | 首次出现 |
|---|---|---|
| VFS | 虚拟文件系统，统一各文件系统接口的层 | 0.3 |
| `super_block` | 一个已挂载的文件系统实例 | 0.4 |
| `inode` | 一个文件的元数据（不含名字） | 0.4 |
| `dentry` | 目录项，名字到 inode 的映射 | 0.4 |
| `file` | 一次打开的会话（含读写位置） | 0.4 |
| page cache | 文件数据的内存缓存 | 0.5 |
| `address_space` | 单个 inode 的 page cache 管理器 | 0.5 |
| folio | 一页或连续多页内存的容器 | 0.5 |
| sector / block / page | 512 / 4096 / 4096（典型值） | 0.6 |
| iomap | 文件偏移 ↔ 磁盘位置 的映射框架 | 0.7 |
| pcluster | 物理压缩簇，解压的基本单位 | 0.8（阶段 4 详讲） |

## 自测检查点

建议先自己想一遍再看答案。答不上来的题，回看对应小节。

1. 一次 `read()` 在 page cache 命中时，请求会到达磁盘吗？为什么这很重要？
2. `inode` 和 `dentry` 为什么要分成两个对象？如果合并成一个，会失去什么能力？
3. 两个进程同时 `open()` 同一个文件，会有几个 `struct inode`？几个 `struct file`？
4. `struct address_space` 到底是什么？（提示：它不是一个笼统的"地址空间"）
5. 内核为什么要从 `struct page` 迁移到 folio？folio 解决了什么歧义？
6. 表达式 `off & (blocksize - 1)` 是在算什么？为什么这样写而不是用 `%`？
7. iomap 框架让文件系统只需要负责哪一件事？
8. EROFS 是只读的。这给它**简化**了什么，又**约束**了什么？
9. 压缩文件系统的"读"为什么不能像非压缩那样做简单算术？列出至少两个原因。
10. 如果页大小是 64KB 而文件系统块大小是 4KB，一页能装几个块？这个场景叫什么？

## 自测答案

<details>
<summary>点击展开答案</summary>

**1. page cache 命中时会到磁盘吗？**

不会。命中意味着数据已在内存，直接拷贝给用户即返回。
**重要的原因**：这说明文件系统的主要工作不是"去磁盘读数据"，
而是"在缓存未命中时告诉内核去哪里读"。
理解这点，才能理解为什么 EROFS 里有大量"映射/翻译"代码而很少"提交 IO"的代码。

**2. inode 与 dentry 为什么要分开？**

因为一个 inode 可以有多个名字（硬链接）。
如果名字存在 inode 里，一个文件就只能有一个名字。
分开之后，`/a.txt` 和 `/b.txt` 可以是两个不同的 dentry 指向同一个 inode。
另外，把路径解析（名字查找）与文件本身解耦，也让 VFS 的路径缓存（dcache）成为可能。

**3. 两个进程 open 同一文件？**

**一个 `inode`，两个 `struct file`。**
inode 代表文件本身（全局唯一），file 代表一次打开会话（每次 open 一个）。
两个 file 各有自己的读写位置，所以两个进程各自 `read()` 不会互相干扰。

**4. `address_space` 是什么？**

它是**单个 inode 的 page cache 管理器**。里面有：缓存了哪些页（xarray 树）、
怎么取页（操作函数集）、统计与标志。
每个 inode 有自己的一个，所以不同文件的缓存是分开管理的。
在 EROFS 代码里看到 `mapping`，就理解成"这块数据属于哪个文件的缓存"。

**5. 为什么要 folio？**

`struct page` 只代表一页，无法表达"这是一组连续页"。
所以拿着一个 `page`，你不知道它是单独一页还是大块内存的一部分——
这个歧义在历史上造成过很多 bug（尤其是 `PageTail`/复合页的判断）。
folio 明确知道自己包含多少页（order），消除了歧义。

**6. `off & (blocksize - 1)` 算什么？**

算 `off` 在块内的偏移，等价于 `off % blocksize`。
因为 blocksize 是 2 的幂（4096 = 2^12），所以可以用位与代替取余。
**原因：性能。** 这在内核热路径上（每次读都要算）能省下除法开销。
同理 `addr >> blkszbits` 等价于 `addr / blocksize`。

**7. iomap 让文件系统只负责哪件事？**

只负责**地址翻译**："文件的这段逻辑范围对应磁盘的哪个物理范围"。
IO 提交、DAX 处理、FIEMAP 支持、readahead 策略等，都由 iomap 框架统一做，
文件系统不必各写一套。

**8. 只读简化了什么、约束了什么？**

- **简化**：不需要空间分配器、不需要日志/崩溃恢复、不需要写路径的复杂锁
- **约束**：数据布局在 mkfs 时定死，运行时无法调整。
  所以格式设计的灵活性必须全部放在 mkfs 侧——
  这直接导致了 EROFS 有 5 种 data layout（阶段 1）：
  `FLAT_PLAIN` / `FLAT_INLINE` / `CHUNK_BASED` / `COMPRESSED_FULL` / `COMPRESSED_COMPACT`。
- **补充**："只读"指 EROFS 镜像不可变，不等于用户看到的系统不可写——
  上层可用 OverlayFS 把写入重定向到另一个可写文件系统。

**9. 压缩为什么不能做简单算术？**

- 压缩后长度不定，无法用"偏移 ÷ 块大小"定位，必须查索引表
- 解压单位（pcluster）与页常常不对齐，一页可能只对应某个 pcluster 的一部分
- 读到的数据是压缩的，还要现场解压才能用
- 同一 pcluster 可能被多个并发读请求需要，需要协调避免重复解压

（答出前两条即算掌握。）

**10. 页 64KB、块 4KB？**

一页能装 **16 个块**。这个场景叫 **sub-page blocksize**
（块比页小，一个页内包含多个块）。
EROFS 声称支持它，但代码里存在若干处理不干净的地方，
阶段 3 会遇到一个相关的遗留疑问。

</details>


## 与后续阶段的关系

- **阶段 1** 会用本章的"块"和"偏移"概念，讲 EROFS 镜像在磁盘上的布局
- **阶段 2** 的 `erofs_buf` 元数据缓存，本质上是**借用一个假 inode 的 `address_space`**——
  不懂 `address_space` 就读不懂它
- **阶段 3** 的非压缩读路径，就是本章 0.5 节"缓存未命中时的五步"的具体实现
- **阶段 4** 展开本章 0.8 节埋下的伏笔：压缩读路径的"映射 → 获取压缩簇 → 解压 → 提供结果"

## 参考
[linux-7.2](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)
