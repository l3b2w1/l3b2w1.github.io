---
layout:     post
title:      EROFS advanced features
subtitle:   EROFS 高级特性
date:       2026-09-11
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 阶段 6：高级特性

> 本章的特性都"挂在主干上"，没有一个独立成体系。
> 按**挂载点**分类记忆，比按字母顺序背清单有效得多。

---

## 📌 先看这里：本章是**概览**，深度内容在特性专题（09–18）

本章用「① 解决什么问题 → ② 磁盘上怎么表示 → ③ 内核怎么用 → ④ 现状与坑」
四段式覆盖 9 个特性，**每个约百行**——目的是让你先建立全景。

**若要深入理解某个特性（关键结构体、主要函数、完整来龙去脉），
请跳转到对应的特性专题**——那里每份都是独立的深度文档（389–631 行）：

| 本章小节 | 深度专题 |
|---|---|
| 6.1 xattr（扩展属性） | 12-特性-xattr扩展属性 |
| 6.2 多设备与 device table | 13-特性-多设备与device-table |
| 6.3 fileio 文件后端 | 09-特性-文件后端 |
| 6.4 FSDAX | 10-特性-FSDAX |
| 6.5 48-bit 地址 | 16-特性-48bit地址 |
| 6.6 fragment 与 ztailpacking | 14-特性-fragment与ztailpacking |
| 6.7 rolling-hash 去重 | 15-特性-rolling-hash去重 |
| 6.8 metabox | 18-特性-metabox元数据压缩 |
| 6.9 ishare（page cache share） | 11-特性-page-cache-sharing |
| —（本章未涉及）硬件解压加速 | 17-特性-硬件解压加速 |

**三对最容易混淆的概念**：

| 混淆对 | 区分要点 |
|---|---|
| **fragment vs tail-packing**（→14） | fragment = 多文件零头**集中**到 packed inode；tail-packing = 单文件尾部**内联**进自己的 inode |
| **dedupe vs fragment**（→15） | dedupe 消除**跨文件相同块**；fragment 处理**压缩后填不满 pcluster 的零头** |
| **DAX vs DIO**（→10） | DIO 仍走块设备层；DAX 完全不走，直接映射持久内存 |

## 本阶段目标

读完这一章，你应该能够：

1. 说出本章每个特性解决什么问题、挂在哪个模块上
2. 解释 xattr 的 inline / shared 两种形式
3. 说清多设备寻址的完整链路，**并解释为什么"镜像分层(layering)"不是内核概念**
4. 区分 fileio 与块设备后端，知道 fscache 后端已被移除
5. 说清 FSDAX 在 EROFS 里的作用与"设备粒度"的真相
6. **区分 fragment 与 rolling-hash 去重**（最容易混淆的一对）
7. 解释 metabox 与 ishare 各自的设计动机

## 前置要求

- 完成阶段 0~5（本章多处引用前面的知识）

## 6.0 全景

![特性地图](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-11-erofs-16-feature-map.svg)

按挂载点分类：

| 类别 | 特性 | 挂在哪个模块上 |
|---|---|---|
| 挂 inode | xattr、metabox | inode 解析 |
| 挂地址解析 | 多设备、48-bit | 映射函数 |
| 挂数据来源 | fileio、FSDAX | 设备/IO 层 |
| 挂压缩路径 | fragment、ztailpacking、去重 | zmap / zdata |
| 挂缓存复用 | ishare | page cache |

下面每个特性按四段式讲：**① 解决什么问题 → ② 磁盘上怎么表示 → ③ 内核怎么用 → ④ 现状与坑**。

## 6.1 xattr（扩展属性）

#### ① 解决什么问题

文件的额外元数据（如 SELinux 标签 `security.selinux`、capabilities）。
Linux 的 xattr 是标准接口，文件系统必须支持。

#### ② 磁盘上怎么表示

两种形式：

| 形式 | 位置 | 适用 |
|---|---|---|
| **inline** | 紧跟在 inode 结构之后 | 少量、仅本文件用的 xattr |
| **shared** | 集中在共享 xattr 区域（`xattr_blkaddr`） | 多个文件**相同**的 xattr |

shared 的价值：容器镜像里成千上万个文件常有相同的 SELinux 标签，
存一份、大家引用，能省下大量空间。

#### ③ 内核怎么用

入口 `erofs_init_inode_xattrs()`（`xattr.c`）：

```c
        vi->xattr_shared_count = ih->h_shared_count;                 /* xattr.c */
        if ((u32)vi->xattr_shared_count * sizeof(__le32) > ...)
                ...  /* 边界检查 */
        vi->xattr_shared_xattrs = kmalloc_objs(uint, vi->xattr_shared_count);  /* :95 */
        ...
        for (i = 0; i < vi->xattr_shared_count; ++i) {               /* :103 */
                ...
        }
```

内联 xattr 从 inode 后面读；shared 的先读出"哪些 shared xattr"的索引数组，
再按索引去共享区取。

#### ④ 现状与坑

⚠️ **xattr 路径是 `erofs_buf` 释放义务断掉过的地方**——这是本项目核查发现的历史 bug。

阶段 2 讲过，`erofs_put_metabuf()` 的调用全靠人工维系。
xattr 的遍历过程中，两个迭代函数之间曾漏掉 `put`。

> **这就是阶段 2 知识的实战检验**：    
> 读 xattr 代码时，看到 `erofs_bread` / `erofs_read_metabuf` 就去找对应的 `put`，
> 尤其是**跨函数**的调用链——最容易漏。

## 6.2 多设备与 device table

![多设备寻址](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-11-erofs-17-multi-device.svg)

#### ① 解决什么问题

一个 EROFS 镜像的数据可以**分布在多个设备/文件**上。
典型场景：容器镜像的分层存储，每层是一个独立的 blob 文件。

#### ② 磁盘上怎么表示

superblock 里有 `extra_devices`（额外设备数）和 `devt_slotoff`（设备表位置）。
每个设备一个槽位（`erofs_fs.h`）：

```c
struct erofs_deviceslot {
        ...
        /* tag[64] / blocks / uniaddr */
};
```

字段含义：
- `tag`：设备标识（用于匹配）
- `blocks`：该设备提供多少块
- `uniaddr`：该设备在**统一地址空间**里的起始块号

#### ③ 内核怎么用

挂载时 `erofs_scan_devices()`（`super.c`）扫描设备表，
把设备信息存进 **idr 树**（`devs->tree`），按设备号索引。

读数据时，映射函数产出 `m_deviceid`，再由 `erofs_map_dev()`（`data.c`）定位设备：

```c
        if (map->m_deviceid) {
                dif = idr_find(&devs->tree, map->m_deviceid - 1);   /* data.c */
                ...
                if (devs->flatdev) {
                        map->m_pa += erofs_pos(sb, dif->uniaddr);    /* :226 */
                        return 0;      /* 扁平模式：还是主设备，只加偏移 */
                }
                erofs_fill_from_devinfo(map, sb, dif);               /* :230 换设备 */
        }
```

三种情况：

| 情况 | 处理 |
|---|---|
| `m_deviceid == 0` | 主设备 `dif0` |
| `m_deviceid != 0`，flatdev 模式 | 仍用主设备，地址加 `uniaddr` |
| `m_deviceid != 0`，正常模式 | 换成对应设备的 `bdev` |

#### ④ 现状与坑 —— ⚠️ **"layer" 不是内核概念**

这是本节最重要的认知。

T4 那条命令看起来很直观：

```bash
mkfs.erofs meta.erofs layer0.erofs layer1.erofs ...
```

**但内核里根本没有 "layer" 这个抽象。**

实证：

```bash
grep -rin layer fs/erofs/
# → 零命中
```

内核看到的是**一个扁平的设备数组**。它不知道：
- 哪个设备是"第几层"
- 层与层之间的依赖关系

"层 N ↔ 设备 N" 的对应关系是 **mkfs 的 rebuild 模式**建立的
（`erofs-utils/mkfs/main.c`，每个输入镜像 `++rebuild_src_count`）。

> **严格说**：EROFS 具备的是"**多设备 / 外部 blob**"这一**能力**，
> layering 是 mkfs 在它之上构建出的**用法**。
>
> 引用时若说"内核支持镜像分层"，会被内核开发者当场纠正。

**另一个易混点**：多 layer ≠ `--blobdev`

| | 多输入镜像（rebuild） | `--blobdev=X` |
|---|---|---|
| 设备数 | = 输入镜像数 | 只建 **1 个**额外设备 |
| device_id | 依次为 1, 2, 3... | **恒为 1** |

## 6.3 fileio 文件后端

#### ① 解决什么问题

镜像不一定在块设备上——它可能只是**一个普通文件**（容器镜像里的一个 layer）。  
传统做法要先 `losetup` 成块设备，麻烦且需要特权。

#### ② 磁盘上怎么表示

镜像本身格式不变，只是**数据来源**从块设备换成了文件。

#### ③ 内核怎么用

```c
/* internal.h */
static inline bool erofs_is_fileio_mode(struct erofs_sb_info *sbi)
{
        return IS_ENABLED(CONFIG_EROFS_FS_BACKED_BY_FILE) && sbi->dif0.file;
}
```

fileio 模式下，`buf->mapping` 指向**后备文件**的 `f_mapping`
（阶段 2 的 `erofs_init_metabuf`，`data.c`），
即借用后备文件系统的 page cache，**避免双重缓存**。

配置：`CONFIG_EROFS_FS_BACKED_BY_FILE`（默认 y）。

#### ④ 现状与坑

**EROFS 早期基于 fscache 的后端已在 7.2 内核被整体移除。**

移除理由：fscache 引入 netfs 硬依赖、不够灵活，
已被 "file-backed mounts + fanotify pre-content hooks" 替代。

> ⚠️ 注意：T2/T3/T4 三份演讲都还在宣传 EROFS over fscache。
> **演讲材料与当前源码已经脱节**——读材料时要注意时间点。

---

## 6.4 FSDAX

#### ① 解决什么问题

让**虚拟机/容器直接访问宿主机的内存**，绕过 guest 的 page cache，
实现"主机与客户机共享镜像缓存"。

#### ② 磁盘上怎么表示

不涉及磁盘格式，是**运行时**能力。

#### ③ 内核怎么用

每个设备可以有一个 `dax_dev`（阶段 2 的 `sbi->dif0.dax_dev`）：

```c
/* super.c */
dif->dax_dev = fs_dax_get_by_bdev(file_bdev(file), ...);
...
if (!dif->dax_dev && test_opt(&sbi->opt, DAX_ALWAYS)) {    /* super.c */
        ...
}
```

挂载选项：`-o dax=always` / `dax=never`。
启用后 iomap 会把 `iomap->dax_dev` 填好（阶段 3 的 `data.c`）。

#### ④ 现状与坑

⚠️ **T4 讲的 "layer-granularity FSDAX" 其实是设备粒度的。**

内核侧是 **per-device** 的 `dax_dev`（每个设备一个），
**没有**专门的 layer 代码。   
所谓"层粒度"，本质上就是"每个 layer 恰好对应一个设备"带来的效果。

这与 6.2 节的认知一致：内核只认设备，不认层。

## 6.5 48-bit 地址

#### ① 解决什么问题

普通 EROFS 用 32 位块地址，最大 2^32 × 4096 = 16 TB。
更大容量的设备需要更多位。

#### ② 磁盘上怎么表示

`EROFS_FEATURE_INCOMPAT_48BIT`（superblock 的 incompat 位）。  
启用后，块地址变成 48 位（与 chunk 地址的低 48 位呼应，见阶段 3）。

#### ③ 内核怎么用

`super.c` 解析 48 位地址。
注意它会**打印警告**：

```c
/* super.c */
erofs_info(sb, "EXPERIMENTAL 48-bit layout support in use. Use at your own risk!");
```

#### ④ 现状与坑

🔶 **实验性**。源码自己就写着 "EXPERIMENTAL ... Use at your own risk!"。

演讲里从未把它当作稳定特性宣传——这是官方的诚实之处。

## 6.6 fragment 与 ztailpacking

#### ① 解决什么问题

**尾部浪费**：每个文件压缩后，尾部往往剩一小段不足一个压缩单元的数据。
如果各自存一个块，浪费巨大。

两个方案：

- **fragment**：把所有文件的尾部压缩数据**合并**放进一个共享的 packed inode
- **ztailpacking**：把尾部数据**内联**在 inode 后面（连 packed inode 都不用）

#### ② 磁盘上怎么表示

| | feature 位 | 数据位置 |
|---|---|---|
| fragment | `INCOMPAT_FRAGMENTS`（`erofs_fs.h`） | packed inode（`packed_nid` 指向） |
| ztailpacking | `INCOMPAT_ZTAILPACKING`（`erofs_fs.h`） | inode 之后（`z_idata_size` 记长度） |

inode 里的标志与字段：

```c
/* zmap.c */
bool fragment = vi->z_advise & Z_EROFS_ADVISE_FRAGMENT_PCLUSTER;   /* erofs_fs.h */
bool ztailpacking = vi->z_idata_size;                              /* internal.h */
```

#### ③ 内核怎么用

在 `z_erofs_map_blocks_fo()` 里（阶段 4 讲过）：

```c
/* zmap.c */
} else if (fragment && m.lcn == vi->z_tailextent_headlcn) {
        map->m_flags = EROFS_MAP_FRAGMENT;                 /* :477 */
} else {
        map->m_pa = erofs_pos(sb, m.pblk);                 /* :479 常规压缩数据 */
        ...
}
```

- `EROFS_MAP_FRAGMENT`：数据在 packed inode 里，要单独读
- ztailpacking：数据在 inode 后，走 `EROFS_MAP_META` + `IOMAP_INLINE`

**fragmentoff 的 64 位组装**（阶段 4 提过，这里补全）：

```c
/* zmap.c —— FINDTAIL 时 */
if (fragment && vi->datalayout == EROFS_INODE_COMPRESSED_FULL)
        vi->z_fragmentoff |= (u64)m.pblk << 32;
```

低 32 位来自 `h_fragmentoff`（header），高 32 位来自尾部索引项被复用的 `pblk` 槽位。
**这是有意的位打包，不是 bug。**

#### ④ 现状与坑

fragment 与 ztailpacking 互斥（`zmap.c` 保证），
不会同时启用。

打包安全：尾部 pcluster 被判为 `EROFS_MAP_FRAGMENT`，
**不会**落到 `erofs_pos(sb, m.pblk)` 那条路径，  
所以被复用的 `pblk` 永远不会被当成块号解释。

## 6.7 rolling-hash 去重（最容易与 fragment 混淆）

![fragment vs 去重](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-11-erofs-18-fragment-vs-dedupe.svg)

#### ① 解决什么问题

不同文件（或同一文件的不同位置）可能含有**完全相同的内容**。
检测到重复后，只存一份，多处引用。

#### ② 磁盘上怎么表示

索引项上的标志位 `Z_EROFS_LI_PARTIAL_REF`（`erofs_fs.h`）。

#### ③ 内核怎么用

```c
/* zmap.c —— 解析索引项时 */
m->partialref = !!(advise & Z_EROFS_LI_PARTIAL_REF);
...
/* zmap.c —— 填进 map 标志 */
if (m.partialref)
        map->m_flags |= EROFS_MAP_PARTIAL_REF;
```

`EROFS_MAP_PARTIAL_REF` 使 `EROFS_MAP_FULL()` 为假，
于是该 pcluster 恒保持 `partial=true`，
解压时按"只解压前缀部分"处理。

#### ④ 现状与坑 —— ⚠️ 与 fragment 的区分

**两者是完全独立的机制**：

| | fragment | rolling-hash 去重 |
|---|---|---|
| 目的 | 合并各文件的**尾部**数据 | 找出**重复内容** |
| 位置 | packed inode | 索引项标志位 |
| mkfs 选项 | `-Efragdedupe` | `-Ededupe` |

**不同材料里叫法不同，但指同一机制**（下列均已回查原文核对）：

| 材料 | 叫法（原文） |
|---|---|
| 内核提交 `5c2a64252c5d`（2022，Gao Xiang） | "variable-length global compressed data deduplication with **rolling hash**" |
| OSS China 2023 | "**variant-CDC** data deduplication" / "per-extent **CDC** dedupe" |
| FOSDEM 2023 | "EROFS compressed data **deduplication**"（未给出算法名） |
| OSS NA 2024 | "**Rolling-hash** compressed data deduplication" |

⚠️ **一个容易混淆的点**：FOSDEM 2023 里出现的 "rolling" 指的是
**rolling decompression**（阶段 4 讲的滚动**解压**），  
与去重的 rolling hash **不是一回事**，别混为一谈。
（同一个词在不同上下文里可能指完全不同的机制 —— 这是读材料时常踩的坑。）

"variant-CDC" 里的 **CDC = Content-Defined Chunking**  
即用 rolling hash 做内容定义的变长切分 ——
与内核提交里的 "variable-length ... rolling hash" 是同一机制，
只是不同场合叫法不同。


> ⚠️ **本项目发现**：`EROFS_FEATURE_INCOMPAT_DEDUPE`（`erofs_fs.h`）
> 内核**从不查询**。
>
> **关于查证方式的说明**：  
> `erofs_sb_has_dedupe()` 在源码里**grep 不到完整的函数名**，  
> 因为它不是手写的函数，而是由 `internal.h` 里的宏**拼接生成**的：
>
> ```c
> #define EROFS_FEATURE_FUNCS(name, compat, feature)                  \
> static inline bool erofs_sb_has_##name(struct erofs_sb_info *sbi)   \
> {                                                                   \
>         return sbi->feature_##compat & EROFS_FEATURE_##feature;     \
> }
> ...
> EROFS_FEATURE_FUNCS(dedupe, incompat, INCOMPAT_DEDUPE)   /* 确实注册了 */
> ```
>
> ⇒ **宏注册了 dedupe，这个函数存在**；但 `fs/erofs/` 里**没有任何调用点**。
> 对照其他特性（调用次数）：
>
> | 函数 | 调用次数 |
> |---|---|
> | `erofs_sb_has_metabox()` | 4 |
> | `erofs_sb_has_48bit()` | 3 |
> | `erofs_sb_has_fragments()` | 1 |
> | `erofs_sb_has_device_table()` | 1 |
> | **`erofs_sb_has_dedupe()`** | **0** |
>
> 所以内核实际上**从不查询**该 feature 位。
>
> 运行时判据是 **per-extent 的标志位**（`Z_EROFS_LI_PARTIAL_REF` 等），
> 不是 superblock 的 feature 位。
>
> 即：镜像不设该位、而 extent 带 partial 标志时，内核**仍会**走去重路径。  
> 是否构成问题取决于 partial-ref 路径自身的校验强度 —— **尚未评估**。

## 6.8 metabox

#### ① 解决什么问题

**增量构建**：往已有镜像里追加文件时，
不想重排整个元数据区（代价太高）。

#### ② 磁盘上怎么表示

superblock 的 `metabox_nid` 指向一个特殊的 inode，
metabox 的元数据放在它里面。

nid 的**最高位**（`EROFS_DIRENT_NID_METABOX_BIT`）作为标记：
置位表示该 inode 的元数据在 metabox 里。

#### ③ 内核怎么用

```c
/* super.c */
... metabox_nid ...
sbi->metabox_nid = le64_to_cpu(dsb->metabox_nid);
if (sbi->metabox_nid & BIT_ULL(EROFS_DIRENT_NID_METABOX_BIT))
        ...
/* super.c —— 挂载时把 metabox inode 读进来 */
inode = erofs_iget(sb, sbi->metabox_nid);
```

两个连带影响（前面阶段提过，这里串起来）：

1. **`erofs_iloc()` 退化**：metabox 里的 inode 位置 = `nid << islotbits`
   （**不加** `meta_blkaddr`，`internal.h`）
2. **`erofs_init_metabuf()` 换 mapping**：用 `metabox_inode->i_mapping`
   （`data.c`）

#### ④ 现状与坑

metabox 引入了**第二个 `mapping`**，
这正是阶段 2 讲的 P0-3（跨 mapping 复用隐患）成为可能的原因。

因为 metabox 的 `mapping` 偏移**从 0 起算**，
与块设备 `mapping` 的低页号区间**天然重叠**，
所以页号碰撞不是理论问题。

## 6.9 ishare（page cache share）

#### ① 解决什么问题

同一台机器上跑几十个容器，每个容器的镜像里有**大量相同的文件**。
如果各自缓存一份，内存浪费巨大。

目标：**内容相同的文件，在内存里只缓存一份**。

#### ② 磁盘上怎么表示

不涉及磁盘格式变化（是运行时优化）。
镜像里可以标记哪些 xattr 用作"指纹"（`ishare_xattr_prefix_id`）。

#### ③ 内核怎么用

思路很巧妙——**复用 VFS 已有的 inode cache**：

```c
/* ishare.c */
si = iget5_locked(erofs_ishare_mnt->mnt_sb,
                  ...,
                  erofs_ishare_iget5_eq,      /* :14 比较指纹 */
                  erofs_ishare_iget5_set,     /* :23 设置指纹 */
                  &fp);
```

做法：
- 建一个**伪文件系统**（`erofs_ishare_mnt`，`ishare.c`）作为指纹 inode 的宿主
- 用文件的"指纹"（某些 xattr 的哈希）作为 key
- 通过 `iget5_locked()` 在伪 fs 里查找/创建 inode
- 指纹相同 → 命中同一个 inode → **共享同一份 page cache**

入口 `erofs_ishare_fill_inode()`（`ishare.c`）。

#### ④ 现状与坑

🔶 **仍是 experimental**（Kconfig `EROFS_FS_PAGE_CACHE_SHARE`）。

设计上有个值得注意的点：**它不复用 fscache**，
而是自己搭了个伪 fs + `iget5_locked` 的方案。  
原因与 6.3 节讲的 fscache 被移除一致——fscache 太重、引入 netfs 硬依赖。

> 这也解释了为什么 EROFS 的"共享缓存"方案出现过两次不同的实现
> （fscache 版 → ishare 版）。

## 术语速查

| 术语 | 含义 | 出处 |
|---|---|---|
| inline / shared xattr | 内联 / 共享的扩展属性 | 6.1 |
| `erofs_deviceslot` | 磁盘上的设备表槽位 | `erofs_fs.h` |
| flatdev | 多设备扁平模式（都在主设备上，只加偏移） | `data.c` |
| fileio | 文件后端（镜像是普通文件） | `internal.h` |
| `dax_dev` | 每设备的 DAX 设备（FSDAX 用） | `super.c` |
| 48-bit | 块地址扩展为 48 位（实验性） | `super.c` |
| fragment | 尾部压缩数据合并进 packed inode | `erofs_fs.h` |
| ztailpacking | 尾部数据内联在 inode 后 | `erofs_fs.h` |
| `Z_EROFS_LI_PARTIAL_REF` | 索引项标志：部分引用（去重） | `erofs_fs.h` |
| metabox | 存放增量构建元数据的区域 | `super.c` |
| ishare | 用伪 fs + `iget5_locked` 做 page cache 共享 | `ishare.c` |
| `iget5_locked` | VFS 的"按自定义 key 查找/创建 inode"接口 | `ishare.c` |

## 自测检查点

1. xattr 有哪两种形式？shared 形式为什么能省空间？
2. 读 xattr 代码时要特别留意什么？（提示：阶段 2 的契约）
3. 多设备的设备信息存在什么数据结构里？按什么索引？
4. `m_deviceid == 0` 时用什么设备？flatdev 模式怎么处理？
5. 为什么说"内核支持镜像分层"这个说法是错的？给出实证方法。
6. 多输入镜像（rebuild）与 `--blobdev` 有什么区别？
7. fileio 后端借用了谁的 page cache？为什么？
8. EROFS 早期的 fscache 后端现在还在吗？
9. FSDAX 的 `dax_dev` 是全局的还是每设备的？T4 讲的"layer 粒度"真相是什么？
10. 48-bit 地址特性的现状如何？内核怎么提示用户的？
11. fragment 与 ztailpacking 的区别？它们能同时启用吗？
12. fragment 与 rolling-hash 去重是同一机制吗？最硬的区分证据是什么？
13. 演讲里的 "variant-CDC" 是什么？为什么和 rolling hash 是一回事？
14. `INCOMPAT_DEDUPE` 这个 feature 位内核会检查吗？有什么影响？
15. metabox 的引入带来了什么副作用？
16. ishare 是怎么复用 VFS inode cache 的？为什么不用 fscache？

## 自测答案

<details>
<summary>点击展开答案</summary>

**1. xattr 的两种形式？**

- **inline**：紧跟在 inode 结构之后，适合仅本文件使用的少量 xattr
- **shared**：集中在共享 xattr 区域（`xattr_blkaddr`），多个文件引用同一份

shared 能省空间，是因为容器镜像里成千上万个文件常有**相同的** SELinux 标签，
存一份大家引用即可。

**2. 读 xattr 代码要留意什么？**

**`erofs_put_metabuf()` 的调用**——尤其是跨函数的调用链。

xattr 路径是本项目核查发现"释放义务断掉过"的地方：
两个迭代函数之间曾漏掉 `put`。
这正是阶段 2 讲的"人工契约"最容易出问题的形态。

**3. 设备信息存在哪？**

存在 **idr 树**里（`devs->tree`），**按设备号索引**。
挂载时由 `erofs_scan_devices()`（`super.c`）扫描设备表填充。

**4. `m_deviceid == 0`？flatdev？**

- `m_deviceid == 0` → 主设备 `dif0`
- flatdev 模式 → **仍用主设备**，但地址加上 `uniaddr`（`data.c`）
- 正常模式 → 换成对应设备的 `bdev`（`data.c`）

**5. 为什么"内核支持镜像分层"是错的？**

因为**内核里没有 layer 抽象**。实证方法：

```bash
grep -rin layer fs/erofs/
# → 零命中
```

内核只看到一个**扁平的设备数组**（idr 树）。
"层 N ↔ 设备 N" 是 mkfs 的 rebuild 模式建立的。

严格说，EROFS 有的是"多设备/外部 blob"能力，
layering 是 mkfs 在其上构建的用法。

**6. rebuild vs --blobdev？**

| | 多输入镜像（rebuild） | `--blobdev=X` |
|---|---|---|
| 设备数 | = 输入镜像数 | 只建 **1 个**额外设备 |
| device_id | 依次 1, 2, 3... | **恒为 1** |

**7. fileio 借谁的 page cache？**

借**后备文件**的 `f_mapping`（`data.c`），
即借用后备文件系统的 page cache，
**避免双重缓存**（同一份数据在内存里存两份）。

**8. fscache 后端还在吗？**

**不在了**。已在 **7.2 内核被整体移除**，
理由是引入 netfs 硬依赖、不灵活，
被 "file-backed mounts + fanotify pre-content hooks" 替代。

⚠️ T2/T3/T4 三份演讲都还在宣传它——材料与源码已脱节。

**9. dax_dev 是全局还是每设备？**

**每设备**的（`dif->dax_dev`）。

T4 讲的 "layer-granularity FSDAX" 真相是：
**设备粒度**的通用多设备 FSDAX，**没有专门的 layer 代码**。
之所以看起来像"层粒度"，只是因为每个 layer 恰好对应一个设备。

**10. 48-bit 现状？**

🔶 实验性。内核会打印警告（`super.c`）：

```
EXPERIMENTAL 48-bit layout support in use. Use at your own risk!
```

**11. fragment vs ztailpacking？能同时启用吗？**

| | fragment | ztailpacking |
|---|---|---|
| 数据放哪 | packed inode | inode 之后 |
| 长度字段 | `z_fragmentoff` | `z_idata_size` |

**不能同时启用**——`zmap.c` 保证二者互斥。

**12. fragment 与 rolling-hash 去重是同一机制吗？**

**不是**，是两套独立机制。最硬的区分证据在 mkfs 侧：
它们是两个**独立的命令行选项** `-Efragdedupe` 与 `-Ededupe`。

**13. variant-CDC 是什么？**

CDC = **Content-Defined Chunking**（内容定义的分块）。
本质就是用 rolling hash 做变长切分。

铁证是内核提交 `5c2a64252c5d` 的 message：
"variable-length global compressed data deduplication with **rolling hash**"。

"variant-CDC" = "rolling hash" = T4 的 "Rolling-hash deduplication"，
**同一机制的三种叫法**。

**14. INCOMPAT_DEDUPE 会被检查吗？**

**不会**。`fs/erofs/` 里没有 `erofs_sb_has_dedupe()` 的调用点。
（该函数由 `internal.h` 的 `EROFS_FEATURE_FUNCS(dedupe, incompat, INCOMPAT_DEDUPE)` 宏生成，
所以源码里 grep 不到完整名字 —— 宏注册存在，但从未被调用。见 6.7 节。）

运行时判据是 **per-extent 的标志位**
（`Z_EROFS_LI_PARTIAL_REF` 等），不是 superblock feature 位。

影响：镜像不设该位、而 extent 带 partial 标志时，
内核**仍会**走去重路径。是否成问题**尚未评估**。

**15. metabox 的副作用？**

它引入了**第二个 `mapping`**（`metabox_inode->i_mapping`），
使阶段 2 讲的 P0-3（跨 mapping 复用隐患）从"理论"变成"可能"。

因为 metabox 的 `mapping` 偏移**从 0 起算**，
与块设备 `mapping` 的低页号区间天然重叠，页号碰撞概率不为零。

**16. ishare 怎么复用 inode cache？**

- 建一个**伪文件系统**（`erofs_ishare_mnt`）
- 用文件指纹（某些 xattr 的哈希）作为 key
- 通过 `iget5_locked()` 在伪 fs 里**按自定义 key** 查找/创建 inode
- 指纹相同 → 命中同一 inode → 共享同一份 page cache

**为什么不用 fscache**：fscache 太重、引入 netfs 硬依赖（已在 7.2 移除）。

</details>

## 参考
[**ATC19 论文**：《EROFS: A Compression-friendly Readonly File System for Resource-scarce Devices》  
OSS China 2023：《EROFS Everywhere: An Image-Based Kernel Approach for Various Use Cases》   
FOSDEM 2023：《EROFS file system update and its future》  
OSS North America 2024：《EROFS: Past, Present, and Future》  
OSS 2019：《EROFS file system》  
[**EROFS 官方文档 Release 0.1**](<https://erofs.docs.kernel.org>)
