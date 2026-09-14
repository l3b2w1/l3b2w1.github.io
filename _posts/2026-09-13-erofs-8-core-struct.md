---
layout:     post
title:      EROFS core struct
subtitle:   EROFS 核心结构体
date:       2026-09-13
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 08 · 核心结构体：关键字段与它们之间的联系

> 本文档是**参考手册**，不是阶段教学。读完整条路线后回头查字段最有用；  
> 也适合在读 03/04 章（读路径）时作为对照表放在旁边。

## 本文档目标（读完你应该能做到什么）

1. 说出 EROFS 里 **5 层核心结构体**分别管什么，以及它们在什么文件里
2. 看到 `sbi->blkszbits`、`vi->datalayout`、`map.m_pa`、`pcl->pos` 这类写法时，
   知道**这个字段从哪来、要到哪去**
3. 能画出（或至少说清）从 `super_block` 到一次解压请求的**结构体引用链**
4. 解释两个反复出现的设计：**为什么 VFS 对象要挂私有数据**、**为什么 inode 里用 union**
5. 不查代码就能回答"压缩数据的页存在哪个结构体里"

## 核心概念（先建立四个"抓手"）

#### 抓手 1：VFS 对象 + 文件系统私有数据

Linux 内核用**通用的** VFS 对象（`super_block`、`inode`、`file`）代表一切文件系统，
但每个文件系统还需要存自己的东西。做法是"挂"上去：

| VFS 通用对象 | 挂在哪 | EROFS 的私有数据 |
|---|---|---|
| `struct super_block` | `s_fs_info` | `struct erofs_sb_info`（简称 **sbi**） |
| `struct inode` | `i_private` | `struct erofs_inode`（简称 **vi**） |

**为什么这样设计**：VFS 层代码不认识 EROFS，它只管传指针；
EROFS 需要额外信息时就从自己的私有结构里取。  
这种"通用外壳 + 私有内核"是内核里最常见的模式。

> 术语：`super_block` 是"超级块"，代表**一个挂载实例**（不是磁盘上的那个超级块，
> 虽然名字一样）；`inode` 是"索引节点"，代表**一个文件或目录**。

#### 抓手 2：datalayout（数据布局）——决定走哪条路

每个 EROFS 文件都带一个 `datalayout`，取值有 5 种（详见 03 章）。
它决定：

- 这个文件的**数据怎么存**（不压缩 / 压缩 / 分块 / 内联 / 尾部打包）
- 进而决定**读它时走哪条代码路径**

⇒ `vi->datalayout` 是 EROFS 里最重要的一个分支依据。

#### 抓手 3：pcluster（物理压缩簇）

**不翻译**。`pcluster` = "物理压缩簇"，是**解压的基本单位**：
一次解压至少处理一个 pcluster。  
它对应磁盘上一段连续的压缩数据。

对比：`lcluster`（逻辑压缩簇）是**压缩前**的固定长度块。
一个 pcluster 通常装多个 lcluster 压缩后的结果。

#### 抓手 4：folio / page cache

`folio` 是"页的容器"，现代内核用它替代 `struct page` 管理内存页
（可以简单理解成"一页内存"，但支持复合页）。  
读文件时，文件内容会先进入 page cache，EROFS 的压缩数据缓存也放这里。

## 代码地图

| 文件 | 里面有什么 |
|---|---|
| `internal.h` | **大部分核心结构体定义**：`erofs_sb_info`、`erofs_inode`、`erofs_map_blocks`、`erofs_buf`、`erofs_device_info`、`erofs_dev_context`、`erofs_map_dev` |
| `super.c` | 挂载流程，填充 `erofs_sb_info` |
| `data.c` | 非压缩读路径，使用 `erofs_map_blocks` |
| `zmap.c` | 压缩文件的地址映射 |
| `zdata.c` | 压缩读路径；`z_erofs_pcluster`、`z_erofs_bvec`、`z_erofs_frontend`、`z_erofs_backend` |
| `compress.h` | `z_erofs_decompress_req`（解压请求） |
| `decompressor.c` / `decompressor_*.c` | 各解压后端 |
| `inode.c` | 填充 `erofs_inode` |

> 📌 引用规范：本文档**只标文件名，不标行号**（行号随版本漂移，标上来很快变成误导）。  
> 需要精确行号请查 `erofs-analysis/` 下的分析文档。

## 图解

#### 图一：全局层与 inode 层

(https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-13-erofs-22-core-structs-overview.svg)

讲两件事：

1. `super_block --s_fs_info--> erofs_sb_info`
2. `inode --i_private--> erofs_inode`

以及 sbi 内部组织了哪些东西（主设备、多设备表、managed cache、pslots）。

**怎么读**：淡蓝是内核通用层，淡黄是重点概念，淡绿/淡橙是非压缩/压缩路径。
实线箭头表示"包含或指向"。

#### 图二：地址映射与压缩解压层

(https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-13-erofs-23-core-structs-io.svg)

讲一次读请求经过的中间对象：

```
erofs_map_blocks  ──►  erofs_map_dev  ──►  （实际读盘）
       │
       └─►  pcluster  ──►  compressed_bvecs[]  ──►  z_erofs_bvec  ──►  page
                │
                └─►  z_erofs_decompress_req  ──►  解压后端
```

**怎么读**：从左到右看，箭尾是容器，箭头是被包含者。虚线表示"数据实际落在哪"。

## 8.1 全局层：`struct erofs_sb_info`（`internal.h`）

一句话：**一个挂载实例的全局信息中心**。代码里到处可见的 `sbi` 就是它。

关键字段（按用途分组）：

| 字段 | 含义 |
|---|---|
| `dif0` | **主设备**（`struct erofs_device_info`，内嵌）。第一个/唯一的设备 |
| `devs` | 多设备表（`struct erofs_dev_context *`），多设备镜像时用 |
| `opt` | 挂载选项（`struct erofs_mount_opts`） |
| `blkszbits` | **块大小的位移值**。块大小 = `1 << blkszbits`（常见 12，即 4096） |
| `islotbits` | inode slot 单位大小的位移 |
| `meta_blkaddr` | **元数据区起始块号**。读所有元数据都要从这开始 |
| `xattr_blkaddr` | xattr（扩展属性）区起始块 |
| `root_nid` / `packed_nid` / `metabox_nid` | 根 / packed / metabox 的 **nid** |
| `managed_cache` | **假 inode**，压缩数据的缓存就挂在它的 `address_space` 上 |
| `managed_pslots` | `xarray`，按物理地址 `pos` 索引 pcluster |
| `packed_inode` / `metabox_inode` | fragment 与 metabox 用的 inode |
| `feature_compat` / `feature_incompat` | 特性标志位（00/01 章讲过） |
| `available_compr_algs` | 镜像里实际用到的压缩算法集合 |
| `device_id_mask` | 设备号用地址的高多少位 |
| `dir_ra_bytes` | 目录预读大小 |
| `domain_id` | ishare（page cache 共享）的域标识 |

> **nid** 是什么？EROFS 不用 inode 号，而用 **nid**（node id）定位 inode 在元数据区的
> 位置。   
> 可以理解为"inode 在磁盘上的编号"。详见 01/02 章。

## 8.2 设备层：一个设备 vs 多个设备

```c
struct erofs_device_info {
	char *path;                    /* 设备路径 */
	struct file *file;             /* 文件后端时用 */
	struct dax_device *dax_dev;    /* FSDAX 用 */
	u64 fsoff, dax_part_off;       /* 在本设备内的偏移 */
	erofs_blk_t blocks;            /* 本设备多少块 */
	erofs_blk_t uniaddr;           /* 统一地址 */
};

struct erofs_dev_context {
	struct idr tree;               /* 额外设备，按 id 索引 */
	struct rw_semaphore rwsem;     /* 保护这张表 */
	unsigned int extra_devices;
	bool flatdev;                  /* 是否 flat 模式 */
};
```

关系：

- `sbi->dif0` 是**主设备**（内嵌，不是指针）
- `sbi->devs` 指向**多设备表**，表里用 `idr tree` 按 id 存额外的 `erofs_device_info`

**设计要点**：为什么设备号要编进地址高 16 位（见 `device_id_mask`）？  
因为这样一次映射（`erofs_map_blocks`）就能同时得到"物理地址"和"在哪个设备上"，  
不用再查表——**把二维信息压进一个数**。

## 8.3 inode 层：`struct erofs_inode`（`internal.h`）

一句话：**EROFS 文件的私有信息**，代码里叫 `vi`。

```c
struct erofs_inode {
	erofs_nid_t nid;               /* 这个 inode 的 nid */
	unsigned char datalayout;      /* ★ 数据布局，决定读路径 */
	unsigned char inode_isize;     /* on-disk inode 占多少字节 */
	unsigned int xattr_isize;      /* xattr 区大小 */
	union {
		erofs_blk_t startblk;      /* 非压缩：数据起始块 */
		struct {
			unsigned short chunkformat;
			unsigned char  chunkbits;
		};                          /* 分块（chunk-based）*/
		struct {
			unsigned short z_advise;
			unsigned char  z_algorithmtype[2];
			unsigned char  z_lclusterbits;
			union {
				u64 z_tailextent_headlcn;
				u64 z_extents;
			};
			erofs_off_t z_fragmentoff;
			unsigned short z_idata_size;
		};                          /* 压缩 */
	};
	struct inode vfs_inode;        /* ★ 内嵌的 VFS inode */
};
```

###### 为什么用 union？

这是**最值得停下来想的一个设计**。

一个文件不可能同时是"非压缩"和"压缩"的，所以 `startblk`、`chunkbits`、
`z_lclusterbits` 这些字段**互斥**。
如果都单独列出，每个 inode 都要浪费内存。

用 `union` 让它们**共用同一块内存**——按 `datalayout` 决定该读哪个成员。

代价是**编译器不会帮你检查**读错成员。所以代码里到处是先判 `datalayout` 再取字段：

```c
if (vi->datalayout == EROFS_INODE_FLAT_INLINE) {
    /* 只有这时 vi->startblk 才有意义 */
}
```

⚠️ **常见错误**：不先判 `datalayout` 就直接读 union 里的成员，
读到的是另一条路径写进去的位——这是 EROFS 里一类真实 bug 的来源。

###### `vfs_inode` 为什么是内嵌而不是指针？

`struct inode`（VFS）和 `struct erofs_inode`（私有）**在同一块内存里**。  
分配时一次申请两块的大小，用 `EROFS_I(inode)` 宏从 VFS 指针算出私有结构位置。

好处：少一次指针跳转、少一次分配。代价：`erofs_inode` 必须是最后一个成员。

## 8.4 地址映射层

#### `struct erofs_map_blocks`（`internal.h`）

**映射的结果**。所有"逻辑偏移 → 物理位置"的查询都填这个结构：

```c
struct erofs_map_blocks {
	struct erofs_buf buf;          /* 内嵌的元数据游标 */

	erofs_off_t m_pa, m_la;        /* 物理地址 / 逻辑地址 */
	u64 m_plen, m_llen;            /* 物理长度 / 逻辑长度 */

	unsigned short m_deviceid;     /* 在哪个设备 */
	char m_algorithmformat;        /* 压缩算法 */
	unsigned int m_flags;          /* 各种标志 */
};
```

`m_la → m_pa` 是 EROFS 的**核心翻译结果**。读路径的一切都建立在它之上。

#### `struct erofs_buf`（`internal.h`）

**元数据游标**。读元数据时需要临时映射一页，用完释放：

```c
struct erofs_buf {
	struct address_space *mapping; /* 元数据所在的 address_space */
	struct file *file;             /* 文件后端时用 */
	u64 off;                       /* 偏移 */
	struct page *page;             /* 当前映射的页 */
	void *base;                    /* 映射后的内核虚拟地址 */
};
```

为什么需要它：元数据可能跨页，反复 `kmap`/`kunmap` 很啰嗦，
用 `erofs_buf` 记住"当前借了哪一页"，避免重复映射。

#### `struct erofs_map_dev`（`internal.h`）

把 `map` 里的 `m_deviceid` 解析成**具体设备**：  
得到 `bdev` / `file` / `dax_dev`加上在本设备内的偏移。多设备时必经这一步。

## 8.5 压缩层

#### `struct z_erofs_pcluster`（`zdata.c`）

**解压的基本单位**。

```c
struct z_erofs_pcluster {
	struct mutex lock;
	struct lockref lockref;        /* 引用计数 + 自旋锁（合二为一）*/
	struct z_erofs_pcluster *next; /* 处理链 */
	erofs_off_t pos;               /* ★ 物理位置 */
	unsigned int length;           /* 解压后长度 */
	unsigned int vcnt;             /* 多少个 bvec */
	unsigned int pclustersize;     /* 簇大小 */
	unsigned short pageofs_out;    /* 输出起始页内偏移 */
	unsigned short pageofs_in;     /* 输入起始页内偏移 */
	unsigned char algorithmformat; /* 压缩算法 */
	bool from_meta;                /* 数据在元数据区（内联）*/
	bool partial;                  /* 部分解压 */
	bool besteffort;
	struct z_erofs_bvec compressed_bvecs[];  /* ★ 柔性数组 */
};
```

两个要点：

1. **`lockref`**：把"引用计数"和"自旋锁"打包进一个 8 字节字，
   用原子操作同时改——这是内核里为高并发场景做的优化。

2. **`compressed_bvecs[]` 是柔性数组**：结构体后面**紧跟**着若干个
   `z_erofs_bvec`，数量由 `vcnt` 决定。这样一次分配就够，不用再单独申请数组。

#### `struct z_erofs_bvec`（`zdata.c`）

描述**一个压缩数据页**：

```c
struct z_erofs_bvec {
	struct page *page;   /* 哪一页 */
	int offset;          /* 页内起始偏移 */
	unsigned int end;    /* 页内结束位置 */
};
```

⇒ 压缩数据的页就在 `page cache` 里，`pcluster` 通过 `compressed_bvecs[]`
找到它们。

#### `struct z_erofs_decompress_req`（`compress.h`）

**交给解压后端的请求**，代码里叫 `rq`：

```c
struct z_erofs_decompress_req {
	struct super_block *sb;
	struct page **in, **out;       /* 输入页数组 / 输出页数组 */
	unsigned int inpages, outpages;
	unsigned short pageofs_in, pageofs_out;
	unsigned int inputsize, outputsize;
	unsigned int alg;              /* 算法 */
	bool inplace_io;               /* 是否原地解压 */
	bool partial_decoding;
	bool fillgaps;                 /* ★ 是否为空隙填零 */
	gfp_t gfp;
};
```

⚠️ `fillgaps` 是个容易踩的字段：它决定"输出里有空隙时是否补零"。  
`fillgaps` 传错会导致数据错误（这正是 09 文档里 D12 那条缺陷的由来——
`keepxcpy` 未初始化，而它会被当作 `fillgaps` 传下去）。

#### `z_erofs_frontend` / `z_erofs_backend`（`zdata.c`）

压缩读路径的两段上下文：

- **frontend**：把一次读请求拆成"要哪些 pcluster"
- **backend**：实际执行解压、把结果填进输出页

它们分工明确：frontend 负责**规划**，backend 负责**执行**。

## 8.6 结构体联系全景（文字版引用链）

从挂载到一次压缩读，结构体是这样串起来的：

```
① 挂载
   super_block.s_fs_info ──► erofs_sb_info (sbi)
        sbi.dif0 ───────────► erofs_device_info（主设备）
        sbi.devs ───────────► erofs_dev_context ──idr──► erofs_device_info（额外设备）
        sbi.managed_cache ──► inode（假，其 address_space 存压缩数据缓存页）
        sbi.managed_pslots ─► xarray：pos ──► z_erofs_pcluster

② 打开一个文件
   inode.i_private ──► erofs_inode (vi)
        vi.datalayout ──► 决定走非压缩 / 压缩 / 分块
        vi.(union) ────► startblk | chunkbits | z_lclusterbits …

③ 读（以压缩为例）
   erofs_map_blocks(realinode, &map)
        ├─ 填 map.m_la / m_pa / m_llen / m_plen / m_deviceid
        ├─ map.buf（erofs_buf）临时映射元数据页
        └─ erofs_map_dev() ──► erofs_map_dev（具体 bdev/file + fsoff）

④ 定位压缩数据
   sbi.managed_pslots[pos] ──► z_erofs_pcluster (pcl)
        pcl.compressed_bvecs[] ──► z_erofs_bvec ──► page（page cache 里的压缩数据）

⑤ 解压
   z_erofs_decompress_req (rq)
        rq.in[] / out[] ← 来自 pcl 与输出页
        rq.alg / fillgaps / partial_decoding
        └─► 解压后端（decompressor*.c）──► 结果填入 out[] 对应的页
```

**一句话总结这条链**：

> `super_block` 找到 `sbi` → `inode` 找到 `vi` → `vi.datalayout` 决定路径 →
> `erofs_map_blocks` 翻译出物理地址 → `pcluster` 组织压缩数据页 →
> `z_erofs_decompress_req` 交给解压后端。

## 8.7 核心设计（为什么会这样设计）

#### 设计 1：通用外壳 + 私有内核

VFS 只定义通用行为，具体文件系统的东西挂在 `s_fs_info` / `i_private`。    
**好处**：VFS 代码可以完全不认识 EROFS；**代价**：要写转换宏（`EROFS_I`）。

#### 设计 2：用 union 表示互斥的布局信息

`erofs_inode` 里非压缩/分块/压缩三套字段互斥，用 union 共用内存。  
**好处**：省内存（inode 数量可能极大）；**代价**：编译器不检查，靠程序员自觉。

#### 设计 3：柔性数组紧跟主体

`compressed_bvecs[]` 放在 `z_erofs_pcluster` 末尾并一次分配。
**好处**：少一次分配、缓存局部性好（数据挨着）。

#### 设计 4：假 inode 做缓存

压缩数据需要有地方缓存，于是造一个"假 inode"（`managed_cache`），
借用它的 `address_space`。  
**好处**：直接复用 VFS 的 page cache 与回收集制，
不用自己写一套。

#### 设计 5：把设备号编进地址高位

一次映射同时得到"地址 + 设备"。
**好处**：少查一次表；**代价**：地址位数要分配，48-bit 地址等特性会受影响。

## 8.8 动手验证

> 结构体在内核内部，用户态看不到。但有几个办法**间接**验证。

#### 验证 1：用 sysfs 看 sbi 的部分字段

EROFS 把 sbi 的一些字段导出到 sysfs（需要 VM 里先挂 sysfs）：

```bash
mount -t sysfs sysfs /sys
ls /sys/fs/erofs/
# 每个挂载的设备一个目录，里面能看到：
#   features        ← 对应 feature_compat / feature_incompat
#   dir_ra_bytes    ← 对应 sbi->dir_ra_bytes
#   sync_decompress ← 解压策略
#   drop_caches     ← 可写，触发缓存回收
```

挂载一个 EROFS 镜像后：

```bash
mount -t erofs /host/comp2.erofs /mnt
cat /sys/fs/erofs/*/features
cat /sys/fs/erofs/*/dir_ra_bytes
```

能实际读到值，就说明这些字段确实挂在 sbi 上。

#### 验证 2：用 dump.erofs 看 on-disk 字段（对应 vi 的来源）

`vi.datalayout` 来自磁盘上的 inode。用 dump 能看到：

```bash
/opt/erofs-utils/bin/dump.erofs --path=/rep.txt /host/comp2.erofs
```

输出里的 `Layout:` 一行就是 datalayout（`3` = 压缩全量）。  
把它和代码里 `vi->datalayout` 的分支对照，能确认"磁盘字段 → 内存结构体"的对应关系。

#### 验证 3：读源码确认字段

最直接也最可靠（所有引用都应以此为准）：

```bash
cd /sdd/linux/linux-stable/fs/erofs
grep -n "struct erofs_sb_info {" internal.h     # 只看行号定位，文档里不写行号
```

对照本文档的字段表逐个看一遍，印象最深。

## 8.9 常见误解（重要）

#### 误解 1：`super_block` 就是磁盘上的超级块

不对。`struct super_block` 是**内存里**的代表一个挂载实例的对象；  
磁盘上那个叫 "on-disk superblock"，读进来后填进 `erofs_sb_info`。  
两者同名但不是一个东西。

#### 误解 2：`erofs_inode` 和 `inode` 是两个独立对象

不对。它们是**同一块内存**的两半：`erofs_inode` 内嵌了 `vfs_inode`，
靠 `EROFS_I()` 宏互转。  
不存在"两个对象同步"的问题。

#### 误解 3：union 里的字段可以同时用

不对。`startblk` / `chunkbits` / `z_lclusterbits` 共用内存，
**只有与 `datalayout` 匹配的那个有意义**。  
不先判断就读是真实 bug 来源。

#### 误解 4：pcluster 一定对应磁盘上连续的一段

基本对，但要注意 `from_meta` 的情况：数据可能在**元数据区**（内联），
不在常规数据区。

#### 误解 5：`erofs_map_blocks` 是函数名也是结构体名

是的，EROFS 里两者同名：

- `struct erofs_map_blocks` —— 结构体（映射结果）
- `erofs_map_blocks()` —— 函数（执行映射，填充结构体）

看代码时要根据上下文区分。

## 自测检查点

1. `super_block` 通过哪个字段找到 `erofs_sb_info`？反过来呢？
2. `vi->datalayout` 为什么能决定读路径？它有几个取值？
3. `erofs_inode` 里的 union 包含哪三套字段？为什么用 union 而不是分开？
4. `struct erofs_map_blocks` 里 `m_la` 和 `m_pa` 分别是什么？哪个是核心翻译结果？
5. 压缩数据所在的页，存在哪个结构体里？通过 pcluster 的哪个字段找到？
6. `z_erofs_pcluster` 的 `compressed_bvecs[]` 为什么用柔性数组？
7. `sbi->managed_cache` 是个"假 inode"，它借用来做什么？
8. `z_erofs_decompress_req` 的 `fillgaps` 字段影响什么行为？
9. 从 `super_block` 到一次解压，说出完整的结构体引用链（至少 5 个结构体）。
10. 为什么说"不先判 `datalayout` 就读 union 成员"是 bug 来源？

## 自测答案

<details>
<summary>点击展开答案</summary>

1. `super_block.s_fs_info` 指向 `erofs_sb_info`；反过来是 `sbi` 所属的 sb
   （通常通过 `inode->i_sb` 或函数参数传递获得）。
   `inode.i_private` 指向 `erofs_inode`，反向用 `EROFS_I(inode)` 宏。

2. 因为 EROFS 按 datalayout 把文件分成不同存储方式，读路径必须先知道是哪种
   才能正确解析。取值有 5 种（见 03 章）：FLAT_PLAIN、FLAT_INLINE、
   COMPRESSED_FULL、COMPRESSED_COMPACT、CHUNK_BASED。

3. 三套：① `startblk`（非压缩）② `chunkbits`+`chunkformat`（分块）
   ③ `z_advise`/`z_algorithmtype`/`z_lclusterbits`/`z_extents`/`z_fragmentoff`/`z_idata_size`（压缩）。
   用 union 因为它们互斥，共用内存能省空间（inode 数量可能极大）。

4. `m_la` 是逻辑地址（文件内的偏移），`m_pa` 是物理地址（磁盘/镜像内的位置）。
   核心翻译结果是 **`m_la → m_pa`**。

5. 压缩数据的页在 **page cache** 里，由 `struct z_erofs_bvec` 描述，
   pcluster 通过 **`compressed_bvecs[]`** 这个柔性数组找到它们。

6. 柔性数组让 `z_erofs_bvec` 紧跟着 pcluster 一次分配完成，
   少一次内存分配、缓存局部性更好（数据挨着）。

7. 借用它的 **`address_space`** —— 把压缩数据缓存挂进 VFS 的 page cache，
   从而复用内核的缓存与回收机制，不用自己写一套。

8. `fillgaps` 决定**输出里有空隙时是否补零**。传错会导致读到错误数据
   （例如 deduped 页未填零）。

9. 一条完整链（示例）：
   `super_block` →(`s_fs_info`)-> `erofs_sb_info`
   →(`managed_pslots`)-> `z_erofs_pcluster`
   →(`compressed_bvecs`)-> `z_erofs_bvec` -> `page`
   → 组装 -> `z_erofs_decompress_req` -> 解压后端。
   另外 `inode` →(`i_private`)-> `erofs_inode` →(`datalayout`)-> 决定路径
   → `erofs_map_blocks` → `erofs_map_dev`。

10. 因为 union 成员共用同一块内存。若当前 datalayout 是压缩，
    却去读 `startblk`，读到的是压缩那些字段写进去的**位模式**，
    数值毫无意义——而且编译器不会报错，只能靠运行时暴露。

</details>

## 参考
[linux-7.2](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)
