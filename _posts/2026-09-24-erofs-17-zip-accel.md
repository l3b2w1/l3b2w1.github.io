---
layout:     post
title:      EROFS zip accel
subtitle:   EROFS 硬件解压加速
date:       2026-09-24
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 17 · 特性专题：硬件解压加速（ZIP_ACCEL）

> 对应配置：`CONFIG_EROFS_FS_ZIP_ACCEL`
> 主源码：`decompressor_crypto.c`（189 行）
> ⚠️ **本机该配置为 `n`（未启用）**——本文件不参与编译，无法在本机实测
>
> 本文回答：**为什么解压需要硬件加速** → **怎么借 Linux 加密框架的 acomp** →
> **引擎表怎么管理** → **关键结构体与函数** → **与本材料已记录缺陷的关系**。

## 本专题目标

1. 说清为什么 CPU 解压会成为瓶颈，以及硬件加速的价值
2. 解释 EROFS 为什么**借用内核 crypto 框架的 `acomp`** 而不是自己写驱动
3. 看懂 `z_erofs_crypto_engine` 与引擎表的组织方式
4. 解释 **为什么引擎表需要锁**
5. 说清 enable / disable / show 三个操作的职责
6. 知道本特性的**实测限制**及其原因

## 前置要求

- 读过 05（解压后端）——必须懂 `z_erofs_decompress_req`
- 知道 Linux crypto 框架提供"异步压缩"（`crypto_acomp`）接口

## 图解

![ZIP_ACCEL：引擎表只有 DEFLATE 挂了一个 qat_deflate](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-24-erofs-36-zip-accel-engines.svg)

**一句话**：引擎表是**静态白名单**——`z_erofs_crypto[alg]` 里只有
`Z_EROFS_COMPRESSION_DEFLATE` 挂了一个 **`qat_deflate`**，
**LZ4 / LZMA / ZSTD 三栏全是空的**（只有结束哨兵）。  
所以"硬件加速"在当前代码里等价于"**DEFLATE 用 QAT**"。

自上而下五段 + 底部澄清：

| 段 | 回答什么 | 一句话 |
|---|---|---|
| **① 引擎表**（★） | 到底哪些算法能加速 | 只有 DEFLATE 有 `qat_deflate`；其余三栏空 ⇒ `get_engine()` 永远返回 NULL |
| **② 引擎条目** | 一项里有什么 | 只有两个字段：`crypto_name`（名字）+ `tfm`（acomp 句柄，NULL = 未启用） |
| **③ 锁** | 为什么只读也要加锁 | `show_engines()` 全程没加锁，而 disable 会并发 `crypto_free_acomp()` → UAF |
| **④ enable 的坑** | 启用时有什么雷 | 名字**不匹配**也 `return 0` —— sysfs 写 typo 会"报成功但什么也没做" |
| **⑤ 一次解压** | 请求怎么走 | `down_read` → 取 tfm → **补齐 `out[]` 缺页** → acomp 提交 → `crypto_wait_req` **同步等** |

**⚠️ 底部红框的三件事**：

1. **不是"都能加速"** —— 表里只有 `qat_deflate`（DEFLATE 专用）。
   论文里大讲的 IAA 并不在这张表里。
2. **"异步接口"不等于"不等待"** —— acomp 是异步接口，
   但这里用 `crypto_wait_req()` **同步阻塞**等结果，调用线程会被卡住。
3. **本机实测不了** —— 内核配置里是
   `# CONFIG_EROFS_FS_ZIP_ACCEL is not set`，该文件根本不参与编译。

## 一、特性缘由：CPU 解压成为瓶颈

#### 1.1 压缩文件系统的代价

EROFS 用压缩换空间，代价是**每次读都要解压**。

在以下场景，CPU 解压会明显成为瓶颈：

| 场景 | 为什么解压吃 CPU |
|---|---|
| **高并发读** | 多个进程同时读，解压请求叠加 |
| **高压缩率算法** | LZMA 解压比 LZ4 慢得多 |
| **冷启动** | 大量文件首次读入，全都要解压 |
| **低端 CPU** | 算力本来就紧张 |

#### 1.2 思路：把解压交给专用硬件

现代平台常带**压缩加速硬件**（如 Intel IAA、各种 SoC 的解压引擎）。
它们做解压比通用 CPU 快、且**不占用 CPU 核心**。

（⚠️ 硬件"存在"不等于 EROFS 就能用——能不能用取决于**引擎表里有没有它**，
见 3.1 与误解 6：IAA 目前并不在表里。）

⇒ **把解压请求卸载到硬件**，CPU 去干别的事。

#### 1.3 为什么不自己写硬件驱动？

Linux 内核已有成熟的 **crypto 框架**，
其中的 **`acomp`（异步压缩）** 子系统已经把各种压缩加速硬件抽象好了。

EROFS 的选择：**直接用 `crypto_acomp`**，
不去接触具体硬件。

好处：

- 支持所有已接入 crypto 框架的加速器
- 不用为每个硬件写驱动
- 接口是异步的（`crypto_acomp`），保留了将来真正异步化的余地

⚠️ **但当前实现是同步等待的**：`__z_erofs_crypto_decompress()` 里是

```c
ret = crypto_wait_req(crypto_acomp_decompress(req), &wait);
```

提交后**立刻阻塞等结果**，调用线程会被卡住。
所以"提交请求后可以去干别的"在当前代码里**并没有发生**（见 3.2）。
硬件带来的收益体现在**解压本身更快 / 不占 CPU 做运算**，而非"调用方不必等待"。

## 二、设计理念

#### 理念 1：作为"解压后端之一"接入

EROFS 的解压后端是可插拔的（05 专题）。
硬件加速只是**其中一个后端**：

```
解压请求
   ├─ LZ4（软件）
   ├─ LZMA（软件）
   ├─ DEFLATE（软件）
   ├─ ZSTD（软件）
   └─ ★ 硬件加速（crypto acomp）——本专题
```

接入点：`z_erofs_crypto_decompress()`。
若硬件可用就用，不可用则返回 `-EOPNOTSUPP` 让上层回退到软件解压。

#### 理念 2：引擎表 + 读写锁

系统里可能有**多个**加速引擎（按算法区分）。
EROFS 用一张表管理：

```c
static DECLARE_RWSEM(z_erofs_crypto_rwsem);   /* 保护引擎表 */
```

**为什么需要锁**：

- **读者**：解压时查表找引擎（并发、频繁）
- **写者**：启用/禁用引擎时会**修改表**（含 `crypto_free_acomp()` 释放）

若不加锁，读者可能拿到**正在被释放**的引擎对象。

#### 理念 3：可运行时开关，并通过 sysfs 暴露

引擎不是写死的，可以运行时：

- **启用**：`z_erofs_crypto_enable_engine()`
- **禁用**：`z_erofs_crypto_disable_all_engines()`
- **查看**：`z_erofs_crypto_show_engines()`

⇒ 运维可以按实际情况调整，不用重新编译内核。

## 三、实现架构

#### 3.1 对象关系

```
z_erofs_crypto_rwsem（读写信号量）
        │ 保护
        ▼
引擎表 z_erofs_crypto[alg]（按算法分组，★ 静态白名单）
        │
        └─► z_erofs_crypto_engine[]
                 ├─ crypto_name    ← 引擎名（当前只有 "qat_deflate"）
                 └─ tfm            ← crypto_acomp 句柄
                                        │
                                        ▼
                                  硬件加速器
```

⚠️ **这张表目前几乎是全空的**——四种算法里只有 DEFLATE 有内容：

```c
static struct z_erofs_crypto_engine *z_erofs_crypto[Z_EROFS_COMPRESSION_MAX] = {
        [Z_EROFS_COMPRESSION_LZ4]     = (...) { {} },                        /* 空 */
        [Z_EROFS_COMPRESSION_LZMA]    = (...) { {} },                        /* 空 */
        [Z_EROFS_COMPRESSION_DEFLATE] = (...) { { .crypto_name = "qat_deflate" }, {} },
        [Z_EROFS_COMPRESSION_ZSTD]    = (...) { {} },                        /* 空 */
};
```

⇒ 查找函数 `z_erofs_crypto_get_engine(alg)` 遍历该 alg 的条目、返回第一个 `tfm` 非空的。
对 **LZ4 / LZMA / ZSTD** 而言它**永远返回 NULL**，只能走软件解压。

⚠️ 顺带纠正本材料早期的一个错：曾用 `"iaa"` 举例，但**表里没有它**
（论文材料里常提的 IAA 并不在这张静态表中）。

#### 3.2 一次硬件解压的流程

```
① 解压请求到来（z_erofs_decompress_req）
        │
② z_erofs_crypto_decompress(rq, pgpl)
        ├ down_read（读锁）
        ├ tfm = z_erofs_crypto_get_engine(rq->alg)
        ├ 若 tfm 为 NULL → 返回 -EOPNOTSUPP（上层回退到软件解压）
        ├ ★ 补齐 rq->out[] 里为 NULL 的页（__erofs_allocpage）
        │　　　—— 硬件解压要求输出页都已就位
        └ __z_erofs_crypto_decompress(rq, tfm)
              ├ 组装 sg table（src / dst）
              ├ acomp_request_alloc + acomp_request_set_params
              ├ crypto_wait_req(crypto_acomp_decompress(req), &wait)
              │　　　★ 同步阻塞等结果（不是"提交完就走"）
              └ 解压结果落在 rq->out[]
        │
③ up_read（释放锁）
```

注意第 ② 步里那个容易被忽略的动作：**先补齐 `rq->out[]` 中的空页**。
软件后端可以边解压边分配，走 acomp 则要求输出散列表先完整。

#### 3.3 与软件后端的分工

关键：**硬件加速是"能则用"**。

```c
err = z_erofs_crypto_decompress(rq, pgpl);
if (err != -EOPNOTSUPP)
        return err;                  /* 硬件搞定了 */
/* 否则继续走软件解压路径 */
```

⇒ 硬件不可用时**自动降级**，不影响正确性。

## 四、关键结构体

#### 4.1 `struct z_erofs_crypto_engine`（`decompressor_crypto.c`）

一个加速引擎的描述：

```c
struct z_erofs_crypto_engine {
	char *crypto_name;              /* 引擎名（当前唯一取值："qat_deflate"）*/
	struct crypto_acomp *tfm;       /* ★ crypto 框架的 acomp 句柄 */
};
```

就这两个字段，没有别的。

**`tfm` 是关键**：它指向 crypto 框架里的一个"压缩变换"对象。
EROFS 通过它提交解压请求，不关心背后是软件还是硬件。

⇒ 为空（`NULL`）表示**该引擎当前不可用/未启用**。

#### 4.2 `z_erofs_crypto_rwsem`

```c
static DECLARE_RWSEM(z_erofs_crypto_rwsem);
```

保护引擎表的读写信号量（见理念 2）。

#### 4.3 `struct z_erofs_decompress_req`（`compress.h`）

硬件解压与软件解压**共用**同一个请求结构（08 专题）：
`in[] / out[]`、`inputsize / outputsize`、`alg` 等。

⇒ 后端可插拔的基础：请求描述统一。

## 五、主要函数

| 函数 | 作用 | 加锁 |
|---|---|---|
| `__z_erofs_crypto_decompress()` | 内部实现：实际提交解压 | （由调用者保证） |
| `z_erofs_crypto_decompress()` | 对外：尝试硬件解压，不可用返回 `-EOPNOTSUPP` | 读锁 |
| `z_erofs_crypto_enable_engine()` | 启用指定引擎（按名字） | 写锁 |
| `z_erofs_crypto_disable_all_engines()` | 禁用全部引擎（释放 `tfm` 并置 NULL） | 写锁 |
| `z_erofs_crypto_show_engines()` | 列出当前可用引擎（供 sysfs） | **读锁**|

#### 5.1 `z_erofs_crypto_decompress()` —— 入口

```c
int z_erofs_crypto_decompress(struct z_erofs_decompress_req *rq,
                              struct page **pgpl)
```

返回值约定很重要：

- 成功 → 0（或已处理的字节数）
- **`-EOPNOTSUPP`** → **硬件不可用，请走软件路径**

⇒ 这个约定让上层能优雅降级。

#### 5.2 `z_erofs_crypto_disable_all_engines()` —— 危险操作

```c
down_write(&z_erofs_crypto_rwsem);
for (alg ...) {
        for (e = z_erofs_crypto[alg]; e->crypto_name; ++e) {
                if (!e->tfm)
                        continue;
                crypto_free_acomp(e->tfm);      /* 释放 */
                e->tfm = NULL;                  /* 置空 */
        }
}
up_write(&z_erofs_crypto_rwsem);
```

**为什么必须用写锁**：它在**修改并释放**引擎对象。
任何并发的读者（解压或 show）若不加锁保护，
就会访问到被释放的 `tfm`。

#### 5.3 `z_erofs_crypto_show_engines()`

```c
int z_erofs_crypto_show_engines(char *buf, int size, char sep)
```

遍历引擎表，把可用引擎名写进缓冲区。

**修复前**：完全不加锁。
**修复后**：`down_read()` / `up_read()` 包住整个遍历。

⇒ 这正是"看似只读、实则必须加锁"的典型场景：
因为**别人可能在并发地释放你要读的东西**。

#### 5.4 `z_erofs_crypto_enable_engine()` —— 名字不匹配也「成功」

```c
int z_erofs_crypto_enable_engine(const char *name, int len)
{
        down_write(&z_erofs_crypto_rwsem);
        for (alg = 0; alg < Z_EROFS_COMPRESSION_MAX; ++alg) {
                for (e = z_erofs_crypto[alg]; e->crypto_name; ++e) {
                        if (!strncmp(name, e->crypto_name, len)) {
                                if (e->tfm)
                                        break;
                                tfm = crypto_alloc_acomp(e->crypto_name, 0, 0);
                                if (IS_ERR(tfm)) {
                                        up_write(&z_erofs_crypto_rwsem);
                                        return -EOPNOTSUPP;   /* 分配失败：有报错 */
                                }
                                e->tfm = tfm;
                                break;
                        }
                }
        }
        up_write(&z_erofs_crypto_rwsem);
        return 0;                                             /* ★ 一个没匹配上也是 0 */
}
```

**问题**：两层循环跑完、一个都没匹配上时，照样 `return 0`。

⇒ 往 `/sys/fs/erofs/<dev>/accel` 写一个 typo，或写 `deflate-iaa`
（表里只有 `qat_deflate`），**store 返回成功，实际什么也没发生**。

**报错路径不对称**：分配失败会返回 `-EOPNOTSUPP`，名字不匹配却是 `0`。
改进建议：记一个匹配计数，为零时返回 `-EINVAL`，让运维立刻知道写错了。

两个附带细节：

- 匹配用 `strncmp(name, e->crypto_name, len)`（`len` 为写入长度），是**前缀匹配**语义
- 已启用（`e->tfm` 非空）时会 `break`，不会重复分配

## 六、来龙去脉：完整串一遍

```
① 内核编译启用 CONFIG_EROFS_FS_ZIP_ACCEL
        │
② 挂载/初始化阶段：引擎表登记有哪些引擎（名字）
     但 tfm 为空 = 未启用
        │
③ 管理员通过 sysfs 启用某引擎
     └ z_erofs_crypto_enable_engine(name, len)
          ├ down_write（写锁）
          ├ 按名字找到引擎条目
          ├ crypto_alloc_acomp(...) 拿到 tfm
          └ up_write
        │
④ 进程读压缩文件
     └ z_erofs_crypto_decompress(rq, pgpl)
          ├ down_read（读锁）
          ├ 查引擎（tfm 非空？）
          ├ 非空 → 提交给 crypto_acomp（硬件解压）
          └ 为空 → 返回 -EOPNOTSUPP → 上层走软件解压
        │
⑤ 卸载/关闭时
     └ z_erofs_crypto_disable_all_engines()
          └ down_write + crypto_free_acomp + tfm = NULL
```

**关键点**：步骤 ④ 的读锁与步骤 ⑤ 的写锁**互斥**——
这就是保证"不会用到已释放引擎"的机制。

## 七、动手验证

#### ⚠️ 验证限制（重要）

本特性在本机**无法实测**，没有硬件解压加速的设备环境。

#### 验证 1：确认配置状态

```bash
grep ZIP_ACCEL /sdd/linux/linux-stable/.config || echo "未启用"
```

#### 验证 2：确认文件被条件编译包围

```bash
cd /sdd/linux/linux-stable/fs/erofs
head -20 decompressor_crypto.c
grep -n "CONFIG_EROFS_FS_ZIP_ACCEL" ../Makefile decompressor_crypto.c
```

确认整个文件受该宏保护。

#### 验证 3：读源码理解加锁（不依赖运行）

```bash
cd /sdd/linux/linux-stable/fs/erofs
grep -n "down_read\|up_read\|down_write\|up_write" decompressor_crypto.c
```

对比各函数的加锁情况——**找出哪个函数少了锁**，

#### 验证 4（需自行启用配置）

若重新配置并启用 `CONFIG_EROFS_FS_ZIP_ACCEL` 重新编译，
才可能实测，且需要实际有加速硬件，否则引擎仍不可用。

## 八、常见误解（重要）

#### 误解 1：硬件加速一定能用

不一定。需要同时满足：

1. 内核编译时启用 `CONFIG_EROFS_FS_ZIP_ACCEL`
2. **实际存在**可用的加速硬件（并已接入 crypto 框架）
3. 引擎已被**启用**（`tfm` 非空）

任一不满足就返回 `-EOPNOTSUPP`，回退软件解压。

#### 误解 2：EROFS 自己驱动硬件

不是。它**借用内核 crypto 框架的 `crypto_acomp`**，
只管"提交请求"，硬件细节由 crypto 框架处理。

#### 误解 3：只读操作不需要加锁

**错**。

只读也要加锁，因为**别人可能在并发地释放你要读的对象**。
`show_engines()` 读 `e->tfm`，而 `disable_all_engines()`
会 `crypto_free_acomp(e->tfm)`——并发下就是 use-after-free。

#### 误解 4：`-EOPNOTSUPP` 是错误

不是错误，而是**"我干不了，请走别的路"的信号**。
上层收到它会回退到软件解压，整个过程对用户透明。

#### 误解 5：启用了 CONFIG 就能实测

还不够。`CONFIG` 只决定**是否编译**。
真要跑起来还需要**实际硬件**；没有硬件时引擎 `tfm` 仍为空。

#### 误解 6：引擎表里什么算法都有（比如 Intel IAA）

**不是。** 当前这张表是**静态白名单**，只有 `qat_deflate` 一项（属 DEFLATE），
**LZ4 / LZMA / ZSTD 三栏是空的**（只有结束哨兵 `{ }`）。
论文材料里常讲的 **IAA 并不在表里**。

⇒ 想给别的算法接硬件后端，得改这张表（或改成动态注册机制）。

#### 误解 7：异步接口 = 调用方不用等

不。acomp 是异步接口，但当前实现用
`crypto_wait_req(crypto_acomp_decompress(req), &wait)` **同步阻塞**等结果。
硬件的收益在于**解压更快、不占 CPU 做运算**，而不是"调用方不必等待"。

## 九、与其他特性的关系

| 特性 | 关系 |
|---|---|
| **解压后端**（05 专题） | 硬件加速是**其中一个可插拔后端** |
| **多设备**（13） | 无关——加速只作用于解压环节 |
| **LZMA / LZ4 等算法** | 按 `alg` 分引擎，不同算法可有不同引擎 |
| **sysfs** | 引擎的启用/查看通过 sysfs 暴露给用户态 |

## 自测检查点

1. 为什么需要硬件解压加速？举两个瓶颈场景。
2. EROFS 为什么不自己写硬件驱动？
3. `crypto_acomp` 在里扮演什么角色？
4. `z_erofs_crypto_engine.tfm` 是什么？为空意味着什么？
5. 为什么引擎表需要锁？读者和写者分别是谁？
6. 为什么"只读"也要加锁？
7. `z_erofs_crypto_decompress()` 返回 `-EOPNOTSUPP` 是什么意思？上层怎么做？
8. `disable_all_engines()` 做了哪两件危险的事？
9. 本特性在本机为什么无法实测？需要满足哪三个条件才能真跑起来？
10. 硬件加速与软件解压如何共存？

## 自测答案

<details>
<summary>点击展开</summary>

1. 解压消耗 CPU，在**高并发读**、**高压缩率算法（LZMA）**、
   **冷启动**、**低端 CPU** 等场景成为瓶颈。
   硬件加速更快且**不占用 CPU 核心**。

2. 因为 Linux crypto 框架的 `acomp` 子系统已经把各种加速硬件抽象好了。
   直接用它能支持所有已接入的加速器，免去为每种硬件写驱动，
   还能自动获得异步能力。

3. 它是 EROFS 与硬件之间的**中间层**。
   EROFS 通过 `tfm` 提交解压请求，由 crypto 框架决定具体怎么执行
   （软件或硬件）。EROFS 不接触硬件细节。

4. `tfm` 是指向 crypto 框架"压缩变换"对象的句柄。
   **为空表示引擎不可用/未启用**，此时解压回退到软件路径。

5. **读者**：解压时查引擎、show 时遍历引擎（并发频繁）；
   **写者**：enable/disable 会**修改表**并 `crypto_free_acomp()` 释放对象。
   不互斥会导致读者访问到已释放的对象。

6. `z_erofs_crypto_show_engines()` 遍历引擎表时**未加锁**。
   **为什么只读也要加锁**：因为 `disable_all_engines()` 会并发地
   `crypto_free_acomp(e->tfm); e->tfm = NULL;`
   ——你读的正是别人在释放的东西（use-after-free）。
   修复：`down_read()` / `up_read()` 包住遍历。

7. 意思是"**硬件不可用，我干不了**"。
   上层收到后会**回退到软件解压**，对用户透明——不是真正的错误。

8. **①** `crypto_free_acomp(e->tfm)` 释放 crypto 对象；
   **②** `e->tfm = NULL` 置空。
   两者都在写锁保护下进行。

9. 本机 `CONFIG_EROFS_FS_ZIP_ACCEL` **未启用**，
   整个 `decompressor_crypto.c` 不参与编译。
   要真跑起来需：**①** 编译启用该 CONFIG；
   **②** 实际存在可用加速硬件并接入 crypto 框架；
   **③** 引擎已被启用（`tfm` 非空）。

10. 硬件加速作为**可插拔后端之一**接入。
    能用就用，不能用返回 `-EOPNOTSUPP` 让上层回退软件——
    自动降级，正确性不受影响。

</details>

## 参考
[linux-stable](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)
