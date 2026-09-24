---
layout:     post
title:      EROFS Business Scenario
subtitle:   EROFS 业务场景
date:       2026-09-24
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 19 · 业务场景：EROFS 在智能手机系统分区的应用

> **本文档讲什么**：把前面 10 份特性专题串到一个真实业务里——
> 智能手机的只读系统分区（`/system` 等）。  
回答：用在什么业务、怎么用、解决什么问题、取得什么效果，以及**这些说法的根据是什么**。

## 论文出处

**本文档的业务数据全部来自这篇论文，不采用厂商宣传口径。**
（论文里有实验条件与对比基线，比"发布会宣称的百分比"可验证得多。）

> Xiang Gao, Mingkai Dong, Xie Miao, Wei Du, Chao Yu, Haibo Chen.
> **《EROFS: A Compression-friendly Readonly File System for Resource-scarce Devices》**
> 2019 USENIX Annual Technical Conference (ATC19).
> 华为技术有限公司 + 上海交通大学。

## 一、业务背景与痛点【论文】

#### 1.1 场景：智能手机的只读系统分区

Android 手机上有几个分区装的是**系统资源**：
`/system`、`/vendor`、`/oem`、`/odm`。

它们有个关键特征（论文原话的意思）：
**一旦 Android 系统安装完成，这些资源几乎不再被修改。**

⇒ 天然适合"只读文件系统 + 压缩"。

#### 1.2 痛点一：系统分区持续膨胀【论文】

论文 Fig.1 给出的数据：

| Android 版本 | `/system` 有效数据 |
|---|---|
| 2.3.6 | **184 MB** |
| 9.0.0 | **1.9 GB** |

另有引用数据：**Android 6.0.0 出厂重置后，整个系统占用约 3.17 GB**。

#### 1.3 痛点二：资源紧张的机型大量存在【论文】

论文开篇的场景设定：

- 低端 Android 手机：**1–2 GB 运行内存 + 8–16 GB 的 eMMC**
- Android 系统本身就能吃掉 3 GB 以上存储
- 即便高端机，常驻应用也在持续吃内存与存储

⇒ **"存储不够用"在当时的低端机上是真实且普遍的痛点**，
而且不能靠"加硬件"解决（成本敏感）。

#### 1.4 痛点三：为什么不能直接上现成的压缩文件系统【论文】

这是最关键的痛点。论文点名了 **Squashfs** 这类"压缩只读文件系统"的两个问题：

**问题一：读放大（read amplification）**

它们用的是 **fixed-sized input compression**（固定**输入**大小压缩）：

```
文件数据 → 切成固定大小的 chunk（例如 128KB）→ 每个 chunk 单独压缩
```

论文给的具体例子：

> 当 Android 只想读**每 128KB 里的前 4KB** 时，
> Squashfs 必须把整个 chunk 的压缩数据读出来、全部解压。

⇒ **读 4KB 要解压 128KB**（论文原话：“when Android reads the first 4KB of every 128KB”）。  
   128/4 = **32 倍是我的推算** —— 论文只说 “significant read amplification”，**没有给出具体倍数**。随机读场景直接崩掉。

**问题二：解压时的内存开销**

解压需要额外内存，而低端机内存本来就紧张（1–2 GB）。

⇒ "省了存储，但内存扛不住、随机读变慢"——**得不偿失**，
这就是当时没法直接用现成方案的原因。

## 二、怎么用：部署方式【论文 + 源码】

#### 2.1 方式：直接替换系统分区的文件系统【论文】

论文明确写到 EROFS 的集成情况：

- **已合入 Linux 4.19** 作为主要特性
- 集成进华为手机操作系统 **EMUI 9.1**，作为 "a top feature"
- 部署规模：**数千万台智能手机**（tens of millions of smartphones）

用法是**直接把只读系统分区的文件系统换成 EROFS**，
压缩 `/system`、`/vendor`、`/odm` 等分区。

#### 2.2 为什么上层无感【源码】

从源码看，EROFS 提供的是**标准 VFS 接口**：

- `address_space_operations`（`erofs_aops` 等，见 08 专题）
- `inode_operations` / `file_operations`
- `iomap` 接口

⇒ 应用、框架层看到的就是一个普通只读目录，**不需要任何适配**。
这是能大规模商用的前提（否则每个 App 都要改）。

#### 2.3 一个源码层面的补充【源码】

论文里没展开、但源码里能看到的配套能力：

- **fileio 文件后端**（09 专题）：不用 loop 设备也能挂镜像——
  这在**容器**场景是关键，手机系统分区则通常直接用块设备
- **ishare 页缓存共享**（11 专题）：多实例共享相同内容的页缓存
- **metabox**（18 专题）：元数据也压缩

⇒ 手机场景主要用到的是**压缩 + 只读简化**这一层；
后面这些是 EROFS 后来扩展的能力（详见各自专题）。

## 三、核心技术机制【源码】

#### 3.1 关键决策：fixed-sized **output** compression【源码 + 论文】

这是整个设计里**最重要的一处**，也是"压缩反而更快"的根源。

对比两种切法：

| | 固定**输入**（Squashfs） | 固定**输出**（EROFS） |
|---|---|---|
| 切什么 | 把**原始数据**切成 128KB | 压缩到**固定大小的输出块** |
| 解压后 | 块大小不定 | **块对齐**（4KB 的整数倍） |
| 读 4KB 时 | 要解压整个 128KB | **只解压目标所在的 pcluster** |

源码侧对应：

- **pcluster**（物理压缩簇）与 **lcluster**（逻辑压缩簇）的区分（04/08 专题）
- `zmap.c` 里对 pcluster 大小的检查，保证其不超过上限
- `zdata.c` 的解压按 pcluster 组织

⇒ **因为输出是块对齐的，随机读某个 4KB 只需解压它所在的那个 pcluster**，
读放大被锁死在单个 pcluster 级别，而不是 128KB。

#### 3.2 内存高效解压【源码 + 论文】

论文提到 EROFS "利用压缩算法（如 LZ4）的特性，设计了不同的内存高效解压方案"。

源码侧体现（05 专题）：

- **in-place 解压**：条件允许时直接解到目标页，省一次拷贝与额外页
- **cached 解压**：用 managed cache（`sbi->managed_cache`）暂存解压结果
- 解压请求统一抽象为 `z_erofs_decompress_req`（`compress.h`）

⇒ 目标就是论文说的："**reduce extra memory usage during the decompression**"。

#### 3.3 只读带来的简化【源码】

只读意味着**不需要为写而存在的结构**（08 专题）：

- 没有 journal（日志区）
- 没有块位图 / inode 位图（全部已分配）
- 元数据更紧凑

⇒ 这部分省下的空间，是"压缩之外"的额外收益。

#### 3.4 小文件优化与去重【源码】

- **inline data / tail-packing**（14 专题）：`z_idata_size` 字段；
  小文件或文件尾部直接内联，省掉一次寻址
- **dedupe**（15 专题）：`INCOMPAT_DEDUPE` 特性；
  系统分区里重复内容（多架构 .so、多语言资源）只存一份。
  
  ⚠️ 论文**并未把它算作 2019 年手机部署的机制** —— 论文 §7 把 deduplication
   与 fiemap、EROFS-fuse 一起列为“未来版本中持续新增的特性”（“continuously adding new
   features, such as deduplication…”）。
   ⇒ 它属于**后来的能力**，不计入论文 §5.7 的实测效果。

## 四、实测效果【论文】

#### 4.1 论文 §5.7 的真实手机实测

实验条件（论文给出）：

- 在低端与高端智能手机上运行**修改过的 Android 9 Pie**
- 压缩 `/system`、`/vendor`、`/odm` 分区
- 对比基线：**Ext4**
- 测试对象：生产团队指定的 **13 个热门应用**的启动时间

| 指标 | 结果 | 出处 |
|---|---|---|
| **空间节省** | **30% – 35%** | 论文 §5.7 |
| **应用启动时间（平均）** | 低端机减少 **5.0%**；高端机减少 **2.3%** | 论文 §5.7，对比 Ext4 |

#### 4.2 论文摘要中的表述（口径不同，勿混淆）

摘要里还有两个更"亮眼"的数字：

| 摘要表述 | 原文 |
|---|---|
| 启动时间 | "reduces the boot time of real-world applications by **up to 22.9%**" |
| 存储占用 | "**nearly halving** the storage usage"（几乎减半） |

> ⚠️ **口径说明（重要）**：
> - 摘要的 **22.9%** 是 **"up to"（最高可达）**，而 §5.7 的 5.0% / 2.3% 是**平均值**。  
>   两者**不矛盾，但不能混用**——不能说"平均提升 22.9%"。
> - 摘要的"几乎减半"（约 50%）与 §5.7 实测的 **30%–35%** 也存在差异。
>
> 我只做了文本提取与对比，**无法确认**这两个口径各自对应的具体测试集
> （摘要可能基于某个特定基准或数据集）。
> ⇒ 引用时请**以 §5.7 的真实手机实测（30%–35%、5.0%/2.3%）为准**，
> 摘要数字作为"最好情况下的上界"理解。

#### 4.3 工程实践中的取舍【论文】

论文 §6 讲了落地经验，有两点特别值得记：

**取舍一：不是所有文件都压缩**

论文原话的意思：有些文件在 EROFS 上读起来**比 Ext4 略慢**，
于是他们把**压缩率低的文件直接不压缩**以保性能。

⇒ 说明 EROFS 不是"全压就完事"，而是**按文件做决策**。

**取舍二：热点数据预解压并 pin 在内存**

他们收集匿名 beta 用户的**文件块访问频率**，
把最常被请求的部分**预先解压并常驻内存**，
以此平衡"存储占用"与"性能"。

⇒ 这是一个很典型的工程做法：用**访问热度**打破"省空间 vs 快"的二元对立。

**取舍三：一个真实故障 —— 漏实现了 page migration**

论文 §6 还讲了一个很实在的教训：手机在 EROFS 上跑**几天之后**，
某些应用会**突然变得极慢**。    
排查下来的根因是：**EROFS 当时没有实现page migration（页迁移）**。

平时它不触发，所以"没实现"看起来无害；但一旦**内存碎片化**，页迁移就是
"能否分配到连续内存"的关键。  
缺了它，连续内存分配失败、应用卡顿。实现 page migration 之后问题消失。

⇒ **不常触发 ≠ 不需要实现**。这是"不完整实现在真实场景暴露"的典型案例。

## 五、对照图

![业务场景对照](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-24-erofs-24-business-scenario.svg)

图上的**每个数字都标注了出处**，未标注的即无根据。

## 六、为什么这个场景特别适合 EROFS【源码 + 论文】

把场景特征与设计假设对齐：

| EROFS 的设计前提 | 手机系统分区是否满足 |
|---|---|
| **只读** | ✅ 系统分区天然只读，装完几乎不改（论文原话） |
| **写一次、读多次** | ✅ 出厂烧录一次，之后全是读 |
| **存储紧张、值得压缩** | ✅ 低端机 8–16GB eMMC，系统占 3GB+ |
| **随机读敏感** | ✅ 应用启动要读大量小文件 |
| **内存也紧张** | ✅ 低端机 1–2GB ⇒ 才需要"内存高效解压" |
| **CPU 相对富余、I/O 是瓶颈** | ✅ 闪存慢，解压的 CPU 开销可被 I/O 节省抵消 |

⇒ **这个场景几乎就是 EROFS 被设计出来的原因**。
理解这一点，比记住任何单个数字都重要。

## 七、⚠️ **不掌握**的信息

按照实事求是的原则，把没根据的部分明确列出，**不做任何推测**：

1. **具体机型**：论文只说"低端/高端智能手机"（配置见 §5.1），**没有**给出具体型号。

2. **EMUI 9.1 之后各版本/各机型的演进数据**：论文截止 2019，

3. **华为内部实际使用的挂载参数**（压缩算法选择、cluster 大小、是否开启 dedupe/metabox 等，论文未披露具体实现参数。

4. **"节省 2GB"这类说法**：这是**外界流传的宣传数字**，
   **论文里没有这个表述**（论文给的是百分比 30%–35%）。
   ⇒ 本文档**不采用**该数字。

5. **摘要 22.9% / "近减半" 与 §5.7 实测的差异**：
   无法确认两者各自对应的测试集，已在 4.2 明确标注。

6. **其他厂商/其他产品线的使用情况**：论文只讲华为，不推断其他厂商。

## 参考
[《EROFS: A Compression-friendly Readonly File System for
Resource-scarce Devices》 - **2019 USENIX Annual Technical Conference (ATC19)**](https://www.usenix.org/system/files/atc19-gao.pdf)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)

#### 延伸阅读

> **EROFS 官方文档**对各个特性（ishare、
> metabox、fileio、FSDAX、48-bit、dedupe、多设备、硬件加速、packed inode 等）
> 都有明确说明，甚至有专门章节（如 §3.2、§5.3 讲 dedupe，Device Table 讲多设备）。

| 文献 | 出处 |
|---|---|
| 《EROFS file system》 | Open Source Summit 2019 |
| 《EROFS Everywhere: An Image-Based Kernel Approach for Various Use Cases》 | OSS China 2023 |
| 《EROFS file system update and its future》 | FOSDEM 2023 |
| 《EROFS: Past, Present, and Future》 | Open Source Summit NA 2024 |
| EROFS 官方文档（Release 0.1） | `https://erofs.docs.kernel.org` |
