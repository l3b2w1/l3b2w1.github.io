---
layout:     post
title:      EROFS practise and contribute
subtitle:   EROFS 动手实践
date:       2026-09-12
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 阶段 7：动手实践与贡献

> 本章的目标是让你**真正跑起来**，并能提交第一个补丁。
> 本章所有命令都在本机验证过（不能用的会明确标注）。

## 本阶段目标

读完这一章，你应该能够：

1. 造出各种 datalayout 的镜像，并用 `dump.erofs` 验证
2. 知道本环境能做什么、不能做什么（以及为什么）
3. 知道 EROFS 的运行时观察手段（ftrace、sysfs）
4. 有一份"第二遍读代码"的顺序建议
5. **从练手缺陷清单里挑一条，写出第一个补丁**
6. 知道向上游贡献的完整流程与收件人

## 7.1 实验环境：能做什么，不能做什么

![实验环境](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-12-erofs-19-lab-loop.svg)

#### 宿主机不能直接挂载，但**虚拟机可以** —— 这是本环境的关键

**本机"正在运行"的内核没有编译 EROFS**，所以宿主机上直接挂载会失败：

```bash
$ grep -i erofs /proc/filesystems
（无输出）

$ mount -o loop -t erofs plain.erofs mnt
mount: /tmp/erofs-lab/mnt: unknown filesystem type 'erofs'.
```

**但这不等于"本环境跑不了 EROFS"。**   
本机 `/home/linux/linux-stable` 的编译产物
`arch/x86/boot/bzImage` **已经启用了完整的 EROFS**（内建，非模块）：

```
CONFIG_EROFS_FS=y                      ← 内建
CONFIG_EROFS_FS_ZIP=y                  ← 压缩
CONFIG_EROFS_FS_ZIP_LZMA=y             ← LZMA
CONFIG_EROFS_FS_ZIP_DEFLATE=y
CONFIG_EROFS_FS_ZIP_ZSTD=y
CONFIG_EROFS_FS_BACKED_BY_FILE=y       ← fileio 文件后端
CONFIG_EROFS_FS_PAGE_CACHE_SHARE=y     ← ishare
CONFIG_9P_FS=y                         ← 9p，用于把宿主机目录共享进 VM
```

⇒ **用 QEMU 启动这个 bzImage，就能在虚拟机里挂载 EROFS 并做全部运行时实验。**  
本章 7.3 之后的所有实测内容（ftrace、sysfs、MD5 校验）都是这样跑出来的。

**启动方式**（本机可用）：

```bash
qemu-system-x86_64 -m 8192 -smp 4 -nographic \
  -kernel arch/x86/boot/bzImage --enable-kvm \
  -initrd /home/linux/erofs/erofs-boot-initrd.img \
  -append "console=ttyS0 rdinit=/init" \
  -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
  -virtfs local,path=/tmp/erofs-lab,mount_tag=host,security_model=none,id=host0 \
  -monitor none -no-reboot
```

倒数第二行的 `-virtfs` 把宿主机的 `/tmp/erofs-lab` 共享进 VM，挂载后即可访问宿主机造好的镜像：  
`mkdir -p /host && mount -t 9p -o trans=virtio,version=9p2000.L host /host`   
也可写进/home/linux/erofs/erofs-rootfs-ext4.img镜像里的启动脚本init里，免了手动执行。

**两个 VM 内的注意点**：

1. **initrd 默认不挂载 sysfs** ⇒ `/sys` 一开始是空的，需要
   `mount -t sysfs sysfs /sys` 才能看到 `/sys/fs/erofs/`。
2. **`accel` 属性不一定存在** —— 它注册在 `#ifdef CONFIG_EROFS_FS_ZIP_ACCEL` 内，
   而本机的内核配置**未启用**该选项（详见阶段 5.4）。

#### 用户态工具链（不需要虚拟机）✅

这三个工具是学习的主力，都**不需要内核支持**：

| 工具 | 路径 | 用途 |
|---|---|---|
| `mkfs.erofs` | `/home/linux/erofs/erofs-utils/mkfs/mkfs.erofs` | 造镜像 |
| `dump.erofs` | `/home/linux/erofs/erofs-utils/dump/dump.erofs` | 看结构 ★ 最有价值 |
| `fsck.erofs` | `/home/linux/erofs/erofs-utils/fsck/fsck.erofs` | 检查一致性 |

**即便不上虚拟机，你依然可以验证阶段 1~6 的大半知识点**——
下面这些只用 `mkfs.erofs` + `dump.erofs` 就能看到，不需要内核支持：

- 5 种 datalayout 的实际产生条件（阶段 1）
- tail-packing 的物理位置（阶段 1、3）
- chunk-based 的空洞表示（阶段 1、3）
- 压缩率与磁盘占用（阶段 1、4）
- 各 feature 位（阶段 6）

**造镜像 + 看结构，本身就是极有效的学习方式。**  
想再进一步（真正挂载、读文件、抓 ftrace、调 sysfs），就按上一节启动虚拟机。

#### 如果连虚拟机也不用：让宿主机内核支持 EROFS

若你希望**宿主机**直接挂载（而不是走 QEMU），需要宿主机内核启用 EROFS：

1. 自行编译内核，打开 `CONFIG_EROFS_FS`、`CONFIG_EROFS_FS_ZIP`
   （以及各算法开关 `EROFS_FS_ZIP_LZMA` / `_DEFLATE` / `_ZSTD`）
2. 或使用发行版提供的已启用 EROFS 的内核（多数现代发行版默认已启用）
3. 容器/沙箱场景需要的是**宿主机**内核支持，guest 内核启用无效

> 对本机而言，走 QEMU 比重新编译宿主机内核划算得多——`bzImage` 已经编译好了。

## 7.2 造出各种布局的镜像（可复现）

下面这套命令**已在本机实测通过**，可以直接复制执行。

```bash
cd /tmp && rm -rf erofs-lab && mkdir -p erofs-lab && cd erofs-lab
M=/home/linux/erofs/erofs-utils/mkfs/mkfs.erofs
D=/home/linux/erofs/erofs-utils/dump/dump.erofs
```

#### ① FLAT_INLINE（小文件整体内联 + 大文件尾部内联）

```bash
mkdir src
printf 'hello' > src/tiny.txt                      # 5 字节，极小
head -c 100000 /dev/urandom > src/big.bin           # 100KB 随机，不可压缩

$M plain.erofs src
$D --path=/tiny.txt plain.erofs
# → Layout: 2，On-disk size: 5（整个内联）

$D --path=/big.bin -e plain.erofs
# → Layout: 2，两个 extent：
#     0: 逻辑 0..98304      → 物理 8192..106496   （主体在独立块）
#     1: 逻辑 98304..100000 → 物理 1264..2960     （尾部内联在元数据区！）
```

**对照阶段 3 的代码**：`data.c` 的 `if (map->m_la < pos)` 就是这两个 extent 的分界，  
而 `pos = (块数 - tailinline) × 块大小 = (25-1) × 4096 = 98304`。**完全对上。**

#### ② COMPRESSED_COMPACT（压缩）

```bash
mkdir src2
yes "EROFS is a read-only compressed file system" | head -c 400000 > src2/rep.txt

$M -zlz4hc comp2.erofs src2
$D --path=/rep.txt -e comp2.erofs
# → Layout: 3，On-disk size: 4096，Compression ratio: 1.02%
#   400000 字节 → 4096 字节
```

**这就是阶段 4 讲的"压缩后长度不定，所以必须查索引"的实证。**

#### ③ FLAT_PLAIN vs CHUNK_BASED（稀疏文件对比）

```bash
mkdir src3
truncate -s 1M src3/sparse.bin
dd if=/dev/urandom of=src3/sparse.bin bs=4096 seek=100 count=1 conv=notrunc

$M chunk.erofs src3                    # 默认 → FLAT_PLAIN
$M --chunksize=65536 chunk2.erofs src3  # 分块 → CHUNK_BASED

$D --path=/sparse.bin -e chunk.erofs
# → Layout: 0，On-disk size: 1048576（空洞也分配了）

$D --path=/sparse.bin -e chunk2.erofs
# → Layout: 4，物理偏移 17592186040320（= 0xFFFFFFFF << 12 = NULL_ADDR = 空洞）

ls -l chunk.erofs chunk2.erofs
# → 1052672  vs  69632   —— 省了 93%
```

#### ④ 看 superblock

```bash
$D -s plain.erofs
# magic: 0xE0F5E1E2
# blocksize: 4096, blocks: 31
# inode metadata start block: 0   （meta_blkaddr）
# root nid: 128
```

**对照阶段 1 的公式**：root inode 偏移 = `0 × 4096 + 128 × 32 = 4096`（块 1 开头）。

#### ⑤ 检查镜像

```bash
/home/linux/erofs/erofs-utils/fsck/fsck.erofs plain.erofs
# 无输出 = 检查通过（exit 0）
```

## 7.3 观察运行时（需要内核支持 EROFS）

本节内容**在本环境无法实操**，但列出方法，供你在支持 EROFS 的环境使用。

#### ftrace / tracepoint

EROFS 源码里有 `trace_erofs_*` 系列，例如：

```c
/* data.c */
trace_erofs_map_blocks_enter(inode, map, 0);
```

用法：

```bash
# 看有哪些 tracepoint
ls /sys/kernel/debug/tracing/events/erofs/

# 跟踪映射过程
echo 1 > /sys/kernel/debug/tracing/events/erofs/erofs_map_blocks_enter/enable
cat /sys/kernel/debug/tracing/trace_pipe
```

**这能让你亲眼看到阶段 3/4 讲的映射过程**——每个读请求触发了哪些映射。

#### sysfs

EROFS 在 `/sys/fs/erofs/<设备>/` 下暴露可调参数（`sysfs.c`）：

| 文件 | 作用 | 相关章节 |
|---|---|---|
| `sync_decompress` | 同步/异步解压策略（默认 `1` = AUTO） | 阶段 5.3 |
| `dir_ra_bytes` | 目录预读字节数 | — |
| `drop_caches` | 手动释放缓存 | — |
| `accel` | 硬件加速引擎（写名字启用） | 阶段 5.4 |

```bash
cat /sys/fs/erofs/loop0/sync_decompress
```

⚠️ 注意 `accel` 的**静默失败**问题（阶段 5.4，也是练手清单第 1 条）。

> **实测提醒**：`accel` **不一定存在**。它注册在
> `#ifdef CONFIG_EROFS_FS_ZIP_ACCEL` 内（`sysfs.c`），  
> 内核没开这个选项就没有该属性文件——本项目实测用的内核就没开，  
> 所以 `ls /sys/fs/erofs/` 只能看到 `features` 和各设备的目录。  
> 想练手清单第 1 条，得先自行编译内核打开
> `CONFIG_EROFS_FS_ZIP_ACCEL`（它 `depends on EROFS_FS_ZIP`）。

另外，VM 的 initrd **默认不挂载 sysfs**，所以 `/sys` 一开始是空的。
手动挂上才能看到上面的内容：

```bash
mount -t sysfs sysfs /sys
ls /sys/fs/erofs/
```

## 7.4 第二遍读代码的顺序建议

第一遍你已经按阶段 0~6 走过一遍。第二遍建议**按代码的实际依赖**读：

| 顺序 | 文件 | 规模 | 重点 |
|---|---|---|---|
| 1 | `erofs_fs.h` | 格式定义 | 先把磁盘格式烂熟于心（阶段 1） |
| 2 | `internal.h` | 内部结构与辅助函数 | `sbi` 字段、`erofs_iloc` 等小函数 |
| 3 | `data.c` | 非压缩读 + 元数据原语 | `erofs_buf` 三件套、`erofs_map_blocks`、iomap 接入 |
| 4 | `inode.c` / `namei.c` / `dir.c` | inode 与目录 | 相对独立，可穿插读 |
| 5 | `super.c` | 挂载与全局状态 | 字段多，按需查即可 |
| 6 | `zmap.c` | 压缩映射 | **慢读**，配合阶段 4 的图 |
| 7 | `zdata.c` | 压缩数据面 | **最慢读**，pcluster 状态机是难点 |
| 8 | `decompressor*.c` | 解压后端 | 可以只挑 LZ4 细看 |
| 9 | `xattr.c` / `ishare.c` / `fileio.c` | 边缘特性 | 最后读，不影响主干理解 |

**读法建议**：

- 不要试图一次读完一个文件。**带着问题读**（"这个字段谁在用？"）
- 每读一个函数，先找它的调用者，理解它在流程中的位置
- 遇到不懂的位运算，**先去 erofs-utils 查这个字段是怎么写进去的**

## 7.5 ⭐ 练手缺陷清单

以下是本项目分析 `fs/erofs/` 时发现的**真实问题**，按难度从易到难排列。  
每条都给出位置、问题、为什么是问题、修法提示。

#### 练手1. 硬件加速引擎名不匹配时**静默成功**

**位置**：`decompressor_crypto.c`

**问题**：`z_erofs_crypto_enable_engine()` 在名字没匹配任何表项时 `return 0`。  
向 `/sys/fs/erofs/accel` 写错名（typo、或 `deflate-iaa`）时，
store 返回成功，但**什么都没发生**。

**为什么是问题**：报错路径不对称——引擎存在但 `crypto_alloc_acomp` 失败时返回 `-EOPNOTSUPP`（用户能看到），
名字没匹配却返回 0。  
运维会误以为加速已启用。

**修法提示**：在双层循环里记一个匹配计数，循环结束若为零则返回 `-EINVAL`
（或 `-ENOENT`），最好在错误信息里列出可用引擎名。

**为什么适合第一个补丁**：改动局限在一个函数内，无兼容性风险，
逻辑清晰，容易写清楚 commit message。

#### 练手2. 压缩路径的 `iomap->addr` 未加 `fsoffset`

**位置**：`zmap.c`

```c
iomap->addr = map.m_pa;          /* 未加 m_dif->fsoffset */
```

**对照**：非压缩路径 `data.c` 是
`iomap->addr = mdev.m_dif->fsoff + mdev.m_pa;`（**加了**）。

**问题**：file-backed 挂载 + `-o fsoffset=X` 时，
FIEMAP 的 `fe_physical` 对压缩文件不含 X，与非压缩文件不一致。

**影响面**：仅 `fe_physical`（SEEK_HOLE/DATA 不读 addr），所以影响有限。

**修法提示**：对照 `data.c` 补上 `erofs_map_dev()` 调用与 fsoff 处理。
注意 `z_erofs_iomap_begin_report` 只用于 FIEMAP / SEEK 这类**只报告不做 IO** 的路径。

#### 练手 3：DIO 分支未调用 `erofs_real_inode`

**位置**：`data.c`

```c
if ((iocb->ki_flags & IOCB_DIRECT) && inode->i_sb->s_bdev) {
        struct erofs_iomap_iter_ctx iter_ctx = {
                .realinode = inode,          /* ← 直接用了 inode */
        };
```

**对照**：`data.c`（read_folio）和 `data.c`（readahead）都调用了
`erofs_real_inode(...)`。

**问题**：`CONFIG_EROFS_FS_PAGE_CACHE_SHARE`（ishare）启用时，
`inode` 可能是"伪 inode"，需要用 `erofs_real_inode()` 拿到真实 inode。
DIO 路径漏了这一步。

**修法提示**：改成 `.realinode = erofs_real_inode(inode, &need_iput)`，  
并处理好 `need_iput` 的释放时机。

⚠️ 由于 ishare 仍是 experimental，这条的**实际影响面需要确认**。

#### 练手 4：`erofs_bread` 的 `buf->off` 处理不对称

**位置**：`data.c` vs `data.c`

```c
pgoff_t index = (buf->off + offset) >> PAGE_SHIFT;   /* :31 加了 buf->off */
...
return buf->base + (offset & ~PAGE_MASK);            /* :64 没加 buf->off */
```

**问题**：算页号时计入了 `fsoff`，算页内偏移时没有。
当 `fsoffset` 不是页大小整数倍时，页号对但指针偏移错。

**修法提示**：先确认挂载期 superblock 自校验
（`super.c` 附近）已经拦下了哪些 `fsoff`，
再决定是修正代码还是加断言/注释说明。

⚠️ 这条的**可达性需要仔细论证**——不要在没有复现路径的情况下声称"修复了数据损坏"。

## 7.6 向上游贡献

![贡献流程](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-12-erofs-20-contribution-flow.svg)

#### EROFS 的维护者

来自 `/home/linux/linux-stable/MAINTAINERS`（实际查证）：

```
EROFS FILE SYSTEM
M:	Gao Xiang <xiang@kernel.org>
M:	Chao Yu <chao@kernel.org>
R:	Yue Hu <zbestahu@gmail.com>
R:	Jeffle Xu <jefflexu@linux.alibaba.com>
R:	Sandeep Dhavale <dhavale@google.com>
```

`M` = Maintainer，`R` = Reviewer。

邮件列表（EROFS 补丁的必送地址）：`linux-erofs@lists.ozlabs.org`

实际操作时不必手抄这些——用脚本自动生成：

```bash
./scripts/get_maintainer.pl <你的.patch>
```

#### 流程要点

**Linux 内核用邮件列表协作，不是 GitHub PR。** 关键工具：

| 工具 | 用途 |
|---|---|
| `git format-patch` | 把 commit 变成 `.patch` 文件 |
| `git send-email` | 发送补丁到邮件列表 |
| `./scripts/checkpatch.pl` | 格式检查**（必过）** |
| `./scripts/get_maintainer.pl` | 算出收件人 |

**commit message 格式**（以 erofs 为例）：

```
erofs: add progress check to LZMA decompression loop

xz_dec_microlzma_run() never returns XZ_BUF_ERROR, so the caller
is responsible for detecting a lack of progress (see
include/linux/xz.h).  Without such a check, a crafted
image can cause the loop to spin forever.

Add a check comparing in_pos/out_pos against the previous
iteration, matching what the DEFLATE and ZSTD backends already do.

Signed-off-by: Your Name <your.email@example.com>
```

要点：
- 首行 `erofs: <一句话摘要>`（`erofs:` 是该子系统的约定前缀）
- 正文重点讲**为什么改**，而不是改了什么
- 结尾 `Signed-off-by:`（表示你遵守 DCO，内核强制要求）

#### 给新手的三条建议

1. **第一个补丁选最简单的**。目的是走通流程，不是证明技术。
   改一行报错提示也完全可以。
2. **先查 erofs-utils**。很多"看起来像 bug"的位运算其实是 mkfs 侧的字段复用
   （阶段 4 的 `zmap.c` 就是活生生的例子）。
3. ** commit message 按"为什么"写**。内核社区最看重"这个改动为什么必要"。

## 自测检查点

1. 本环境能挂载 EROFS 吗？如果不能，你还能验证哪些知识？
2. 造一个 5 字节的文件，它的 datalayout 是什么？为什么？
3. 造一个 100KB 的随机数据文件，为什么它有两个 extent？第二个 extent 的物理偏移在哪？
4. 压缩率 1.02% 是怎么来的（给出原始大小与磁盘大小）？
5. 稀疏文件用 `--chunksize` 后，空洞的物理地址显示成什么？怎么判断它是空洞？
6. `0xFFFFFFFF << 12` 等于多少？它代表什么？
7. EROFS 有哪些 tracepoint 可用？举一个例子。
8. `/sys/fs/erofs/` 下有哪两个可调参数？各自作用？
9. 练手清单里，哪一条最适合作为第一个补丁？为什么？
10. `decompressor_crypto.c` 的静默失败问题，正确修法是什么？
11. Linux 内核贡献用 PR 还是邮件列表？关键工具有哪几个？
12. EROFS 的维护者是谁？怎么自动获取收件人？
13. commit message 首行应该怎么写？正文重点讲什么？
14. 为什么改 EROFS 代码前建议先查 erofs-utils？
15. 第二遍读代码，建议从哪个文件开始？为什么？

## 自测答案

<details>
<summary>点击展开答案</summary>

**1. 本环境能挂载吗？**

**不能**。实测：

```
$ grep -i erofs /proc/filesystems
（无输出）
$ mount -o loop -t erofs plain.erofs mnt
mount: unknown filesystem type 'erofs'
```

但仍可验证：5 种 datalayout 的产生条件、tail-packing 的物理位置、
chunk-based 的空洞表示、压缩率与磁盘占用、各 feature 位。
**造镜像 + 看结构已能覆盖大半知识点。**

**2. 5 字节文件的 datalayout？**

**Layout 2（FLAT_INLINE）**。因为数据太小，
直接内联在 inode 后面比分配一个整块（4096 字节）划算得多。

**3. 100KB 随机文件为什么两个 extent？**

因为它是 FLAT_INLINE：前 98304 字节在独立数据块，
最后 1696 字节不足一块，被内联到 inode 后面
（实测物理偏移 1264，在元数据区内）。

对照代码 `data.c` 的 `if (map->m_la < pos)`，
其中 `pos = (25-1) × 4096 = 98304`。

**4. 压缩率 1.02%？**

原始 400000 字节，磁盘占用 4096 字节：

```
4096 / 400000 = 1.02%
```

（用 `yes "EROFS is a read-only compressed file system" | head -c 400000` 造出的
高度重复数据，压缩效果极好。）

**5. 空洞显示成什么？**

显示 `17592186040320`。

判断方法：`17592186040320 / 4096 = 4294967295 = 0xFFFFFFFF`
= `EROFS_NULL_ADDR`（-1）= 空洞。

**6. `0xFFFFFFFF << 12`？**

```
0xFFFFFFFF × 4096 = 17592186040320
```

代表 `EROFS_NULL_ADDR`，即**空洞**（该 chunk 没有对应的磁盘块）。

**7. tracepoint？**

EROFS 有 `trace_erofs_*` 系列，例如
`trace_erofs_map_blocks_enter`（`data.c`）。

用法：

```bash
ls /sys/kernel/debug/tracing/events/erofs/
echo 1 > /sys/kernel/debug/tracing/events/erofs/erofs_map_blocks_enter/enable
cat /sys/kernel/debug/tracing/trace_pipe
```

**8. sysfs 的两个参数？**

- `sync_decompress`：同步/异步解压策略（阶段 5.3）
- `accel`：硬件加速引擎名（阶段 5.4，注意静默失败问题）

**9. 哪条最适合第一个补丁？**

**练手 1**（`decompressor_crypto.c` 的静默失败）。

理由：改动局限在一个函数内、无兼容性风险、
逻辑清晰、容易写清楚 commit message。

（练手 2 的纯注释补丁也很安全，同样适合作起点。）

**10. 静默失败的正确修法？**

在双层循环里记录匹配计数，循环结束若为零返回 `-EINVAL`（或 `-ENOENT`），
最好在错误信息里列出可用引擎名。

目的是让报错路径对称：
引擎存在但分配失败 → 报错；名字没匹配 → **也要报错**。

**11. PR 还是邮件列表？**

**邮件列表**。关键工具：
`git format-patch`、`git send-email`、
`./scripts/checkpatch.pl`（必过）、`./scripts/get_maintainer.pl`。

**12. 维护者？如何获取收件人？**

维护者（来自 `MAINTAINERS`）：

- M: Gao Xiang `<xiang@kernel.org>`
- M: Chao Yu `<chao@kernel.org>`
- R: Yue Hu、Jeffle Xu、Sandeep Dhavale

自动获取：

```bash
./scripts/get_maintainer.pl <你的.patch>
```

**13. commit message？**

- 首行：`erofs: <一句话摘要>`（`erofs:` 是子系统约定前缀）
- 空行
- 正文：重点讲**为什么改**
- 空行
- `Signed-off-by: 你的名字 <邮箱>`（内核强制要求，表示遵守 DCO）

**14. 为什么先查 erofs-utils？**

因为很多"看起来像 bug"的位运算，
其实是 **mkfs 侧的字段复用**。

典型例子：阶段 4 的 `zmap.c`
（`vi->z_fragmentoff |= (u64)m.pblk << 32`）
看起来像"块号当字节用"，
但查 erofs-utils 后确认：`m.pblk` 这个槽位被 mkfs 复用，
存的是 `fragmentoff` 的高 32 位——**是有意设计，不是 bug**。

先查 mkfs，能避免误报，也能更快理解设计意图。

**15. 第二遍从哪个文件开始？**

**`erofs_fs.h`**（磁盘格式定义）。

理由：EROFS 的一切操作都围绕磁盘格式展开。
先把格式烂熟于心，读代码时才能理解"为什么要这么算"。

顺序建议：`erofs_fs.h` → `internal.h` → `data.c` →
inode/namei/dir → `super.c` → `zmap.c` → `zdata.c` →
`decompressor*.c` → 边缘特性。

</details>

## 学到这里


如果你走到了这里，并且做过其中大部分实验——
你已经不是 EROFS 的读者了。

**最后一步是挑一条缺陷，写出补丁。**
能改代码的人和只能读代码的人，差别就在这一步。

推荐路线：

```
练手 1（accel 静默失败）
   → 走通 format-patch / checkpatch / send-email 全流程
   → 收到第一封 review 邮件
   → 练手 2、3、4
```

祝你顺利。
