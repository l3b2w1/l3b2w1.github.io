---
layout:     post
title:      EROFS Overview
subtitle:   EROFS 概览
date:       2026-09-02
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - fs
    - ai
---

# EROFS 文件系统概览

> 资料来源：USENIX ATC'19 论文、官方内核文档、OSS 2019 / OSS China 2023 / FOSDEM 2023 / OSS NA 2024 共 6 份演讲
>
> 由AI整理归纳总结

---

## 1. 什么是 EROFS

**EROFS（Enhanced Read-Only File System，增强型只读文件系统）**   
是华为于 2017 年底发起的高性能只读文件系统，2018 年 7 月以 staging 驱动进入 Linux 4.19，  
2019 年 9 月底合入 5.4-rc1（merge window），随 Linux 5.4（2019 年 11 月正式发布）成为内核树内文件系统。

它的定位是 **通用的高性能只读文件系统**，既可用作块设备上的只读镜像，也可作为可随机访问（seekable）的归档格式，以替代传统的 cpio / tar。

核心特点一句话概括：**以块对齐（block-aligned）的固定输出压缩为基础，在保证高压缩比的同时实现零 I/O 读放大和低内存开销的解压**。


## 2. 开发的缘由与目的

### 2.1 背景问题

随着 Android ROM 膨胀，低端设备（部分仅 16GB 存储）用户可用空间紧张，需要压缩以"省出 1~2GB 空间"。  
而可被无损压缩且收益明显的文件，主要是 **BIN、共享库、APK、预加载配置文件等只读文件**（照片/视频/电影无损压缩无收益，数据库存在覆写 IO 会损害性能）。

### 2.2 为什么 SquashFS 不够好

SquashFS 作为当时主流的只读压缩文件系统，在嵌入式/手机等对内存受限的设备上实时解压存在硬伤：

1. **额外内存开销** —— 解压需临时缓冲；
2. **明显的读放大（read amplification）** —— 默认 128KB 块尺寸下，随机读一个小文件也要搬动一整个 128KB 压缩块；
3. **元数据解析需同步完成** —— 受其磁盘布局设计限制，部分元数据解析必须在关键路径上同步进行。

### 2.3 EROFS 的设计目标

| 目标 | 含义 |
|------|------|
| **高压缩密度** | 减少镜像体积，节省存储 |
| **零 I/O 读放大** | 块对齐，数据 I/O 完全被利用 |
| **低内存/无 memcpy 解压** | 适合内存受限设备 |
| **简单、自包含、安全** | 抵御远程恶意镜像，减少复杂解析带来的内核攻击面 |
| **可复现构建** | 业界少有的对可复现镜像友好的设计 |
| **灵活部署** | 支持块设备、fscache、TarFS、文件后端等多种形态 |


## 3. 顶层架构设计

EROFS 在架构上可分为四层：**用户态工具（erofs-utils）→ 内核文件系统层 → 解压引擎 → 底层块/分发后端**。

```
┌─────────────────────────────────────────────────────────┐
│  使用场景层                                               │
│  Android 系统/APEX | 容器镜像 (Nydus/Composefs/gVisor)     │
│  TarFS Snapshotter | LiveCD | 云原生共享磁盘             │
└───────────────────────────┬─────────────────────────────┘
                            │ mount
┌───────────────────────────┴─────────────────────────────┐
│  内核 EROFS 文件系统层                                     │
│  · inode / 目录 / xattr 解析                              │
│  · 块对齐 I/O (支持 Direct I/O, FSDAX, mmap)             │
│  · 多设备 / fscache / 文件后端分发                        │
└───────────────────────────┬─────────────────────────────┘
                            │ 命中压缩数据
┌───────────────────────────┴─────────────────────────────┐
│  解压引擎（四种策略 × 两种缓冲）                          │
│  cached(vmap) | per-CPU buffer | rolling | in-place      │
│  算法: LZ4 / LZMA / DEFLATE / Zstd / (QAT 硬件加速)      │
└───────────────────────────┬─────────────────────────────┘
                            │
┌───────────────────────────┴─────────────────────────────┐
│  数据分发后端                                             │
│  块设备 | 多设备 | fscache (网络/对象存储) | 文件后端    │
└─────────────────────────────────────────────────────────┘
```

**用户态工具 erofs-utils** 负责镜像构建（mkfs.erofs），  
支持按文件透明压缩、ztailpacking（尾部打包）、chunk 去重、原生分层合并（`--tar=f` 逐层构建 + `meta.erofs` 合并）等。


## 4. 核心创新：固定输出压缩（Fixed-Output Compression）

这是 EROFS 区别于 SquashFS/cramfs 的根本设计。

| 方案 | 做法 | 问题 |
|------|------|------|
| 块边界压缩（Btrfs） | 数据按 4KB 物理块边界对齐压缩 | 仅在 CR≫2 时有收益，对 4K 块压缩很困难 |
| 固定输入压缩（SquashFS/cramfs） | 每 128KB 原始数据压缩成不定长块 | 随机读读放大严重，需搬动整个大块 |
| **固定输出压缩（EROFS）** | 用滑动窗口压满整个 4KB 输出块 | 解压最多碰 **2 个** 块，读放大小 |

**三大优势**：
1. **存储密度提升** —— 高压缩比（CR 高 → 大多数模式 I/O 更少 → 读性能提升）；
2. **解压 in-place** —— 相比固定输入压缩无需 memcpy；
3. **与块边界对齐兼容** —— 支持零 I/O 读放大。

### 压缩率实测对比（LZ4）

| 数据集 | erofs 4k | squashfs 4k | squashfs 128k | btrfs 128k |
|--------|---------:|------------:|--------------:|-----------:|
| enwik9 | 558MB (1.79) | 621MB (1.61) | 398MB (2.51) | 657MB (1.52) |
| silesia | 105MB (2.01) | 114MB (1.85) | 81MB (2.59) | 104MB (2.03) |

> 注：小簇尺寸（4K）下 EROFS 压缩密度已优于 SquashFS；大簇下 SquashFS 密度更高，但代价是随机读放大的急剧上升。

## 5. 解压方案

EROFS 解压策略在 **两个维度** 上组合：

- **维度 1 — Cached 还是 In-place IO 解压**
  - *Cached*：压缩数据读入页缓存后解压（当前默认）；
  - *In-place*：利用 LZ4 64KB 滑动窗口的回溯特性，压缩数据直接读入目标页原地解压，**无需 bounced buffer、无 memcpy**。
- **维度 2 — 缓冲策略**
  - **Cached (vmap)**：映射到页缓存；
  - **Per-CPU buffer**：每 CPU 临时缓冲；
  - **Rolling**：滚动缓冲流式解压；
  - **In-place**：如上，受限 bounced buffer（LZ4 仅需 64KB）。

**为何需要 In-place**：纯 cached 解压会引入页缓存抖动（cache thrashing）；考虑大量一次性/低频使用数据，in-place 可显著减少内存占用。  
由于所有 LZ 系算法都用滑动窗口，EROFS 只需有限的 64KB（LZ4）bounced buffer 即可完成 in-place 解压。

## 6. 磁盘格式（On-Disk Format）

设计哲学：**几乎所有 EROFS 磁盘结构都严格对齐、布局在单个文件系统块内（绝不跨块），以获得最佳性能与简单性**。

- **Superblock**：位于偏移 **1024 字节**，魔数 `0xE0F5E1E2`，小端（little-endian），默认 4K 块（nobh）；元数据与数据可混合布局。
- **Inode**：32 字节 / 64 字节两种；NID → inode 的 **O(1)** 定位公式：
  ```
  inode_offset = meta_blkaddr × block_size + 32 × nid
  ```
- **数据布局类型（layout）**：
  - `FLAT_PLAIN = 0`：普通平面数据；
  - `FLAT_INLINE = 2`：数据内联进 inode / 尾部打包（ztailpacking / fragments）；
  - `CHUNK_BASED = 4`：基于 chunk 的数据（用于大文件、去重、多设备引用）。
- **目录格式**：目录项按文件名 **字典序排序**，通过二分查找加速；目录文件由 inode base、xattrs、tail-packing 内联目录数据、目录块组成。
- **其他**：支持扩展属性与 POSIX ACL、多设备、块对齐（支持 Direct I/O / FSDAX / 页缓存 mmap）。


## 7. 压缩算法与内核演进时间线

| 内核版本 | 特性 |
|---------|------|
| 4.19 | 作为 staging 驱动合入（2018/07） |
| 5.3 | 解压 in-place 合入 |
| 5.4 | 正式成为树内文件系统 |
| 5.16 | LZMA 支持；多设备（原生分层的多设备形式） |
| 6.1 | 全局（压缩）数据去重 |
| 6.6 | DEFLATE 支持 |
| 6.10 | Zstandard 支持 |
| 6.11 | 大 folio (large folio) 支持 |
| 6.12 | file-backed mounts（弃用 EROFS over fscache） |
| 6.16 | Intel QAT 硬件压缩加速 |
| 6.17 | 元数据压缩 |

> EROFS over fscache（5.19 引入）用于 Nydus 等懒加载场景，6.12 起由 file-backed mounts 取代。


## 8. 数据去重（Deduplication）

- **全局压缩数据去重（6.1+）**：用滚动哈希（Rabin-Karp）做**字节粒度**切分，一个 pcluster 可被多次以前缀形式引用；  
对含大量小压缩 pcluster 的文本文件尤其友好（最小 extent 4KiB）。
- **Chunk 去重**：未压缩数据以 4KiB 粒度去重，适合微小差异版本。

**实测效果**：
- enwiki 两个近邻版本（20 天差、1.8G）子文件去重：erofs[64k] **988M** vs squashfs[128k] 1110M。
- ubuntu:jammy 10 个安全小版本（总 766.1MiB）：
  - 压缩 OCI (tar.gz) 282.5MiB（省 63.1%）
  - **未压缩 EROFS 4k 去重 109.5MiB（省 86%）**
  - **压缩 EROFS DEFLATE 46.5MiB（省 94%）**，与 SquashFS+GZIP(47.0MiB) 相当但块更小、随机读更优。

## 9. 子镜像分层合并（Native Layering）

通过 `mkfs.erofs --tar=f` 将各层分别构建为子镜像，再用 `meta.erofs` 以极小元数据合并多层：

```
layer0.erofs  layer1.erofs  …  layerN.erofs
        └──────── 合并 ────────► meta.erofs (tiny metadata)
```

**典型用例**：
1. **共享磁盘（多节点）**：把公共基础层放共享盘，用 (un)compressed 去重最小化镜像与 I/O；
2. **FSDAX 分层内存访问**：传统快照式 FSDAX 只能做镜像级去重（N 倍内存开销），EROFS 子镜像合并使每个 PMEM 区域可由多个子镜像组成；
3. **runC 页缓存共享**：同内容文件（跨 runC / VM 运行时）可共享页缓存（上游 WIP）。

## 10. 应用场景与生态

| 场景 | 说明 |
|------|------|
| **Android 系统分区** | 华为 EMUI 9.0.1 起全系新机；小米、OPPO、vivo、三星等均已采用；APEX 模块 |
| **容器镜像** | Nydus + Dragonfly（lazy-pulling 懒加载）、Composefs、gVisor（PR#9486）、Kata、containerd snapshotter、OverlayBD |
| **TarFS / TarFS Snapshotter** | 以 tar 形式直接挂载，作为可寻址归档 |
| **LiveCD / 云原生** | Fedora LiveCD、云原生共享镜像 |

**社区维护者**：Xiang Gao（阿里云）、Chao Yu（OPPO）、Yue Hu（酷派）、Jingbo Xu（阿里云）、  
Sandeep Dhavale（Google）、Hongbo Li（字节跳动）、Tiwei Bie（蚂蚁/贡献 gVisor）等。

## 11. 性能与安全性

### 11.1 性能（USENIX ATC'19 实测）
- 应用启动：13 个 App 启动相比 Ext4 平均快约 2~23%（低端机约 5.0%、高端机约 2.3%，带 FIO 后台负载时高端机约 10.9%，单应用最大 22.9%）；
- 与固定输入压缩方案相比，随机读/顺序读 I/O 放大显著降低，内存占用更少；
- 多线程解压具有良好的扩展性。

### 11.2 安全性
- 采用简单、自包含的端到端核心格式，尽力抵御远程恶意镜像；
- 经 syzbot 持续加固；对比实验中，特制的恶意 EXT4 镜像可在 CentOS 8/9 上分别 **挂起（hang）或触发内核 panic**，而 EROFS 对恶意镜像具备更强鲁棒性。

## 12. 路线图

- 引入硬件压缩加速器：Intel QAT / IAA 等，卸载云端负载；
- sub-page block 解压（子块粒度）；
- 扩展更多云原生与沙箱场景（Composefs、gVisor、runC 页缓存共享等）；
- 元数据压缩与更大 folio 的持续优化。

## 附：关键数字速查

- 魔数：`0xE0F5E1E2`，superblock @ 1024B
- inode 定位：meta_blkaddr × block_size + 32 × nid
- 解压最多触及块数：2（固定输出压缩）
- in-place 所需 bounced buffer：64KB（LZ4）
- enwik9 4K 压缩：erofs 558MB(1.79) / squashfs 621MB(1.61)
- ubuntu:jammy 10 版本去重：EROFS DEFLATE 46.5MiB（省 94%）
- 应用启动加速（vs Ext4）：平均约 2~23%（ATC'19 表 3）
- 默认压缩簇：4KB（erofs 内核实现）

---

## 参考
[EROFS Release 0.1](https://erofs.docs.kernel.org/_/downloads/en/latest/pdf/)  
[EROFS file system](https://hosted-files.sched.co/ossna2024/eb/oss_na24_EROFS.pdf)   
[EROFS: A Compression-friendly Readonly File
System for Resource-scarce Devices](https://www.usenix.org/system/files/atc19-gao.pdf)  
[EROFS: Past, Present, and Future]  
[EROFS file system update and its future]  
[EROFS Everywhere: An Image-Based Kernel Approach for Various Use Cases]  
