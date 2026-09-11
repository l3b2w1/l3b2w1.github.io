---
layout:     post
title:      EROFS back-end decompression
subtitle:   EROFS 后端解压
date:       2026-09-11
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 阶段 5：解压后端

> 本章聚焦**解压后端的设计与实现**：算法如何抽象、如何挂接，
> 同步与异步如何取舍，硬件加速如何接入。  
> 读完你应该能说清"一个解压请求从发出到完成，中间经过了哪些设计决策"。

## 本阶段目标

读完这一章，你应该能够：

1. 说出 EROFS 的解压后端是怎么抽象和挂接的
2. 区分四种压缩算法的特点与适用场景，知道各自的 Kconfig 开关
3. **解释同步解压与异步解压的选择逻辑**，以及 12288 这个阈值的来历
4. 说清硬件加速（crypto accel）的接入方式与现实限制
5. 说清后端实现的**关键设计约定**（错误返回、进展检测归属、请求结构），
   以及为什么硬件加速只支持 DEFLATE

## 5.1 统一的后端接口

![解压分派](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-11-erofs-09-13-decompress-dispatch.svg)

EROFS 用一个结构体统一抽象所有解压算法（`compress.h`）：

```c
struct z_erofs_decompressor {
        int (*config)(struct super_block *sb, struct erofs_super_block *dsb,
                      void *data, int size);
        const char *(*decompress)(struct z_erofs_decompress_req *rq,
                                  struct page **pagepool);
        int (*init)(void);
        void (*exit)(void);
        char *name;
};
```

五个成员：

| 成员 | 作用 |
|---|---|
| `.config` | 读镜像里的算法参数（比如 LZ4 的滑动窗口大小） |
| `.decompress` | **真正的解压函数**，返回错误信息字符串或 NULL |
| `.init` / `.exit` | 模块加载/卸载时调用（比如初始化算法所需的缓冲池） |
| `.name` | 算法名 |

**这种"函数指针表 + 每种算法一个文件"的组织方式**，
是内核里支持多算法的标准做法。  
加一个新算法只需：
写一个 `decompressor_xxx.c`，实现这几个函数，注册进去。


## 5.2 四种算法

| 算法 | 源文件 | 特点 | Kconfig |
|---|---|---|---|
| **LZ4** | `decompressor.c` | 默认、最快、支持 in-place | 无独立开关（随 `EROFS_FS_ZIP`） |
| **microLZMA** | `decompressor_lzma.c` | 压缩率高，解压较慢 | `EROFS_FS_ZIP_LZMA` |
| **DEFLATE** | `decompressor_deflate.c` | 兼容性好，**唯一支持硬件加速** | `EROFS_FS_ZIP_DEFLATE` |
| **ZSTD** | `decompressor_zstd.c` | 压缩率/速度平衡好（v6.10 合入） | `EROFS_FS_ZIP_ZSTD` |

**几点需要注意**：

**LZ4 是默认的**。绝大多数 EROFS 镜像用它，
因为解压速度是只读场景的第一优先级（尤其是手机启动场景）。

**LZ4 有两种数据排布**：`SHIFTED` 和 `INTERLACED`
（阶段 4 的 `zmap.c` 选择）。  
区别在于压缩数据在内存页里的摆放方式，
`INTERLACED` 在特定情况下对多页 pcluster 更友好。

**microLZMA 用的是 XZ 的 microLZMA 变体**，
通过内核的 `xz_dec_microlzma_run()` 调用。  
注意它属于**流式（streaming）**接口：
调用方要自己维护输入/输出缓冲并循环推进（见 5.5 的设计约定）。

**算法是在 inode 上指定的**，不是全局的
（`vi->z_algorithmtype[0]` / `[1]`，每个文件可以不同）。  
这也是为什么 `z_erofs_map_blocks_fo()` 要把算法格式填进 `map`。

## 5.3 ⭐ 同步解压 vs 异步解压

![同步 vs 异步](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-11-erofs-09-14-sync-vs-async.svg)

解压可以在**当前进程上下文**完成（同步/前台），
也可以丢给**工作队列**后台完成（异步）。

选择逻辑在 `z_erofs_runqueue()`（`zdata.c`）：

```c
static int z_erofs_runqueue(struct z_erofs_frontend *f, unsigned int rabytes)
{
        ...
        int syncmode = sbi->sync_decompress;                        /* :1790 */
        bool force_fg;

        force_fg = (syncmode == EROFS_SYNC_DECOMPRESS_AUTO && !rabytes) ||   /* :1794 */
                (syncmode == EROFS_SYNC_DECOMPRESS_FORCE_ON &&
                        (rabytes <= Z_EROFS_MAX_SYNC_DECOMPRESS_BYTES));     /* :1796 */
        ...
}
```

### 三种策略

`sbi->sync_decompress`（`internal.h`）可以取三个值：

| 值 | 行为 |
|---|---|
| `AUTO`（默认） | 非预读请求（同步读）→ 前台；预读 → 后台 |
| `FORCE_ON` | 请求大小 ≤ 12288 字节 → 前台；否则后台 |
| `FORCE_OFF` | 一律后台 |

### 阈值 12288 从哪来？

```c
/* zdata.c */
#define Z_EROFS_MAX_SYNC_DECOMPRESS_BYTES       12288
```

`12288 = 12 KB = 3 页`。

**为什么是这个数？** 背后的权衡是：

异步解压的额外开销包括：提交工作项 → 唤醒工作线程 → 上下文切换 → 执行 → 回调。  
对于只需解压几 KB 的请求，**这套流程的开销可能超过解压本身**。

所以设一个阈值，小于它就"小活自己干"。这是内核里常见的模式。

> 这个数不是理论推导出来的，是实测调优的结果。  
> 遇到这类"魔法数字"时，合理的做法是：理解它权衡的是什么，而不是纠结为什么不是 12000。

### 可以亲手调

sysfs 接口（`sysfs.c`）：

```
/sys/fs/erofs/<设备>/sync_decompress
```

读它看当前值，写入可切换策略。

## 5.4 硬件加速（crypto accel）

EROFS 可以借用内核 crypto 子系统的 **acompress**（异步压缩/解压）接口，
把解压卸载到硬件（如 Intel QAT）。

**先澄清一个常见的困惑**：这里的 "crypto" 是内核的密码学/压缩算法框架
（`crypto/acompress`），**不是加密**。EROFS 不做加密。

### 现实限制

```c
/* decompressor_crypto.c */
static struct z_erofs_crypto_engine *z_erofs_crypto[Z_EROFS_COMPRESSION_MAX] = {
        [Z_EROFS_COMPRESSION_LZ4] = (struct z_erofs_crypto_engine[]) {
                {},                                          /* 空 */
        },
        [Z_EROFS_COMPRESSION_LZMA] = (struct z_erofs_crypto_engine[]) {
                {},                                          /* 空 */
        },
        [Z_EROFS_COMPRESSION_DEFLATE] = (struct z_erofs_crypto_engine[]) {
                { .crypto_name = "qat_deflate", },
                {},
        },
        [Z_EROFS_COMPRESSION_ZSTD] = (struct z_erofs_crypto_engine[]) {
                {},                                          /* 空 */
        },
};
```

**这是一张静态白名单，不是自动发现机制。**

- LZ4 / LZMA / ZSTD 三档的引擎数组**全空**
- 只有 DEFLATE 有一项：`"qat_deflate"`

**IAA 能用于 EROFS 吗？不能**，三层障碍：

1. 白名单里没有 `deflate-iaa`
2. IAA 是 **4 KiB 滑窗**，而 mkfs 默认 deflate `dict_size` 是 32K
   （`erofs-utils/lib/compressor_deflate.c`）
3. `iaa_comp_adecompress` 要求 src/dst 各自 `nr_sgs == 1`，
   而 EROFS 会跨多页建 sg

> 有意思的旁证：T4 那份 2024 年官方演讲大讲 IAA 加速，
> 但其数据来自 `fsck.erofs` + **用户态** QPL 库，  
> 演讲自己也说 "In-kernel decompression support is still ongoing"。
> **演讲里的数字不等于内核路径的能力**——读材料时要留意这一点。

### 一个附带的可用性缺陷

`z_erofs_crypto_enable_engine()`（`decompressor_crypto.c`）
在**名字没匹配任何表项**时，返回 `0`（成功）：

```c
        for (alg = 0; alg < Z_EROFS_COMPRESSION_MAX; ++alg) {
                for (e = z_erofs_crypto[alg]; e->crypto_name; ++e) {
                        if (!strncmp(name, e->crypto_name, len)) {
                                ...
                                tfm = crypto_alloc_acomp(e->crypto_name, 0, 0);
                                if (IS_ERR(tfm)) {
                                        up_write(&z_erofs_crypto_rwsem);
                                        return -EOPNOTSUPP;   /* 分配失败：有报错 */
                                }
                                ...
                        }
                }
        }
        up_write(&z_erofs_crypto_rwsem);
        return 0;                                             /* 名字没匹配：也返回 0 */
```

**报错路径不对称**：引擎存在但分配失败 → 报错；
名字根本没匹配 → 报成功。

后果：向 `/sys/fs/erofs/accel` 写错名（typo、或想用 `deflate-iaa`）时，
**store 返回成功，但什么都没发生**。运维会误以为加速已启用。

> 这是一条很好的练手补丁（改动局限在一个函数内，无兼容性风险）。
> 阶段 7 的练手清单里有它。


## 5.5 后端设计要点回顾

把本章涉及的设计决策汇总一下——**这些才是后端实现的主干**。

### 算法怎么抽象：函数指针表 + 一个算法一个文件

`struct z_erofs_decompressor`（`compress.h`）用五个成员把算法差异收拢：

| 成员 | 作用 |
|---|---|
| `.config` | 读镜像里的算法参数（如 LZ4 滑窗大小） |
| `.decompress` | **真正的解压函数**，返回错误字符串或 NULL |
| `.init` / `.exit` | 模块加载/卸载时调用 |
| `.name` | 算法名 |

好处是**可插拔**：加一种新算法只需写一个 `decompressor_xxx.c`
实现这几个函数并注册，调用方（`zdata.c`）完全不用改。

### 请求怎么描述：统一 req

所有后端共用 `struct z_erofs_decompress_req`（`compress.h`）
描述一次解压：  
输入页数组 / 输出页数组、页内偏移、长度、
算法、以及若干控制标志。

⇒ 后端**不需要知道**调用方是同步还是异步、是预读还是同步读——
它只看到"一份输入、一份输出"。

几个容易忽略的标志：

| 标志 | 含义 |
|---|---|
| `inplace_io` | 是否允许原地解压（省一次拷贝） |
| `partial_decoding` | 只要部分输出即可 |
| `fillgaps` | 输出有空隙时是否补零 |

### 算法怎么选：每 inode 指定，不是全局

算法存在 inode 里（`vi->z_algorithmtype[0]` / `[1]`），
所以**同一个镜像里不同文件可以用不同算法**。  
映射阶段 `z_erofs_map_blocks_fo()` 把算法格式填进 `map->m_algorithmformat`，
后端据此分派。

### 同步还是异步：看请求特征

`z_erofs_runqueue()`（`zdata.c`）按"是否预读"与"请求大小"（阈值 12288 = 3 页）决定：  
小请求 / 同步读 → 前台解压（降延迟）；
预读 → 后台队列（不干扰前台）。

### 硬件加速：白名单 + 异步接口

通过内核 crypto 子系统的 `acomp`（异步压缩）接入，
但引擎来自**静态白名单** `z_erofs_crypto[]`（`decompressor_crypto.c`），  
其中只有 DEFLATE 档填了 `"qat_deflate"`，其余三档为空。

### 两条容易踩的约定（重点）

**① 错误返回：`decompress` 返回"字符串或 NULL"**

不是返回 `int`。NULL 表示成功，非 NULL 是**错误信息字符串**，
由上层统一上报。写新后端时别搞错返回类型。

**② 进展检测：是调用方的责任（若库契约不保证报错）**

这一点值得单独强调，因为它容易被忽略：

解压循环通常写成"反复调用库函数直到完成"，
循环退出条件依赖库函数**主动报错**。
但有些库的契约并不保证"无法推进时会返回错误"。

例如 `include/linux/xz.h` 明确说明：
microLZMA 的 `xz_dec_microlzma_run()` **不会返回 `XZ_BUF_ERROR`**，  
因此"本轮既没消耗输入也没产出输出"这种情况，
**需要调用方自己检测**并退出，否则循环可能一直空转。

⇒ 写后端时的正确姿势：**若所用库的契约不保证无进展会报错，
循环里必须自己比对输入/输出位置是否有变化。**

> 📌 这不是某个后端的特例，而是一条通用设计原则：
> **循环的正确性不能只依赖被调函数"一定会报错"。**

## 术语速查

| 术语 | 含义 | 出处 |
|---|---|---|
| `z_erofs_decompressor` | 解压后端的统一接口 | `compress.h` |
| SHIFTED / INTERLACED | LZ4 的两种数据排布 | `zmap.c` |
| `rabytes` | 本次预读的字节数（非预读时为 0） | `zdata.c` |
| `force_fg` | 是否在前台（当前上下文）解压 | `zdata.c` |
| `Z_EROFS_MAX_SYNC_DECOMPRESS_BYTES` | 同步解压阈值 = 12288（12KB） | `zdata.c` |
| `sync_decompress` | 同步策略（sysfs 可调） | `internal.h`、`sysfs.c` |
| acompress | 内核 crypto 子系统的异步压缩接口 | 5.4 |
| `z_erofs_crypto[]` | 硬件引擎静态白名单 | `decompressor_crypto.c` |
| `XZ_BUF_ERROR` | microLZMA **不会**返回它（契约） | `include/linux/xz.h` |

## 自测检查点

1. `struct z_erofs_decompressor` 有几个成员？各干什么？
2. 四种算法里，哪个是默认的？哪个是唯一支持硬件加速的？
3. 压缩算法是全局配置还是每个文件可以不同？
4. `force_fg` 在 `AUTO` 模式下什么情况为真？
5. 阈值 12288 字节等于几 KB / 几页？为什么小请求适合同步解压？
6. `sync_decompress` 可以从哪里调整？
7. 硬件加速为什么只支持 DEFLATE？白名单里有什么？
8. IAA 为什么用不了？列出至少两个障碍。
9. 向 `/sys/fs/erofs/accel` 写一个不存在的引擎名，会发生什么？为什么这是问题？
10. `z_erofs_decompress_req` 描述一次解压，其中 `inplace_io` / `partial_decoding` / `fillgaps` 各管什么？
11. 加一种新压缩算法，需要改哪些文件？调用方（`zdata.c`）要改吗？为什么？
12. 写解压循环时，为什么"循环退出条件不能只依赖被调函数报错"？以 microLZMA 的契约为例说明。

## 自测答案

<details>
<summary>点击展开答案</summary>

**1. 接口成员？**

五个（`compress.h`）：

- `.config`：读镜像里的算法参数
- `.decompress`：真正的解压函数
- `.init` / `.exit`：模块加载/卸载
- `.name`：算法名

**2. 默认算法？唯一支持硬件加速的？**

- 默认：**LZ4**（无独立 Kconfig，随 `EROFS_FS_ZIP` 启用）
- 唯一支持硬件加速：**DEFLATE**
  （白名单 `z_erofs_crypto[]` 里只有 `"qat_deflate"` 一项）

**3. 全局还是每文件？**

**每个文件可以不同**。算法存在 inode 的 `z_algorithmtype[0]` / `[1]` 里，
映射时填进 `map->m_algorithmformat`。

**4. AUTO 模式下 force_fg 何时为真？**

看 `zdata.c`：

```c
force_fg = (syncmode == EROFS_SYNC_DECOMPRESS_AUTO && !rabytes)
```

即 **`rabytes == 0`（不是预读请求）时为真**。

直觉：同步读（应用正在等数据）→ 就地解压，降低延迟；
预读（后台猜测性读取）→ 丢到后台，不干扰前台。

**5. 12288 字节？**

```
12288 = 12 KB = 3 × 4096 = 3 页
```

小请求适合同步，是因为异步的流程开销
（提交工作项 → 唤醒线程 → 上下文切换 → 执行 → 回调）
**可能超过解压本身的开销**。

**6. 从哪调整？**

sysfs：`/sys/fs/erofs/<设备>/sync_decompress`（`sysfs.c`）。
可读可写。

**7. 为什么只支持 DEFLATE？**

因为硬件引擎是靠**静态白名单** `z_erofs_crypto[]` 提供的
（`decompressor_crypto.c`），
而白名单里只有 DEFLATE 档填了 `"qat_deflate"`，
LZ4 / LZMA / ZSTD 三档的数组都是空的 `{}`。

**8. IAA 为什么用不了？**

三层障碍（答出两条即可）：

1. 白名单里没有 `deflate-iaa`
2. IAA 是 **4 KiB 滑窗**，而 mkfs 默认 deflate `dict_size` 是 32K
3. `iaa_comp_adecompress` 要求 src/dst 各自 `nr_sgs == 1`，
   而 EROFS 会跨多页建 sg

**9. 写不存在的引擎名会怎样？**

`store` **返回成功（0），但什么都没发生**。

因为 `z_erofs_crypto_enable_engine()`（`decompressor_crypto.c`）
在名字没匹配任何表项时走完两层循环后 `return 0`。

这是问题，因为**报错路径不对称**：
引擎存在但 `crypto_alloc_acomp` 失败时返回 `-EOPNOTSUPP`（用户能看到），
名字根本没匹配时却返回 0。
运维会误以为硬件加速已启用。

**10. `z_erofs_decompress_req` 的三个标志？**

（`compress.h`）

| 标志 | 含义 |
|---|---|
| `inplace_io` | 是否允许原地解压（可省一次拷贝与额外页） |
| `partial_decoding` | 只解出部分输出即可，不必全部 |
| `fillgaps` | 输出存在"空隙"时是否补零（去重/共享页场景会用到） |

**11. 加一种新算法要改什么？**

- 新增一个 `decompressor_xxx.c`，实现 `.config` / `.decompress` / `.init` / `.exit` / `.name`
- 在 Kconfig 里加对应开关，并把它注册进算法表
- **调用方（`zdata.c`）不用改**——因为它只依赖 `struct z_erofs_decompressor` 这个函数指针表，
  算法差异被接口吃掉了。这正是"可插拔"的意义。

**12. 为什么循环退出不能只依赖被调函数报错？**

因为**不是所有库都保证"无法推进时会返回错误"**。

典型例子：`include/linux/xz.h` 明确说明
microLZMA 的 `xz_dec_microlzma_run()` **不会返回 `XZ_BUF_ERROR`**。
也就是说，当"本轮既没消耗输入、也没产出输出"时，
它仍可能返回 `XZ_OK` 而不报错。

⇒ 此时若循环只靠"库返回错误"来退出，就会**一直空转**。

正确做法：循环里记录上一轮的输入/输出位置，
本轮结束后比对，若两者都没变 → 判定无进展 → 报错退出。
**进展检测的责任在调用方。**

</details>


## 参考
[linux-7.2](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)
