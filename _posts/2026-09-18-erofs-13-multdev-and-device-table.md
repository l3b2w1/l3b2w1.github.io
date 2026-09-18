---
layout:     post
title:      EROFS multdev and device table
subtitle:   EROFS 多设备和设备表
date:       2026-09-18
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 13 · 特性专题：多设备与 device table

> 相关源码：`super.c`（挂载时建表）、`data.c`（`erofs_map_dev()` 解析）、
> `internal.h`（`erofs_device_info` / `erofs_dev_context`）
> 配置：随主功能编译，无独立 CONFIG
>
> 本文回答：**为什么要一个文件系统挂多个设备** → **两种模式（flat / 非 flat）差在哪** →
> **地址怎么编码与解析** → **关键结构体与函数** → **一次跨设备读的来龙去脉**。

## 本专题目标（读完你应该能做到什么）

1. 说清多设备解决什么场景问题
2. 区分 **flatdev** 与**非 flat** 两种模式，说清各自的地址含义
3. 看懂 `device_id_mask`（设备号编入地址高 16 位）的设计动机
4. 解释 `erofs_map_dev()` 的三条分支分别在做什么
5. 说清 `uniaddr` 是什么、flat 模式为什么直接加它
6. 解释 ⚠️ **"layer（镜像分层）不是内核概念"** 这个重要澄清

## 一、特性缘由：为什么要多设备

#### 1.1 场景：一个镜像放不下 / 想复用

几种情况需要"一个 EROFS 跨多个设备"：

| 场景 | 说明 |
|---|---|
| **容量** | 单个设备放不下整个镜像 |
| **拆分存储** | 数据与元数据分到不同介质（如元数据放高速盘） |
| **复用** | 多个镜像共享同一块"基础数据"，只各自带增量 |

EROFS 的做法：允许挂载时指定**多个设备**，
镜像里的地址可以指向其中任意一个。

#### 1.2 关键澄清：⚠️ "layer" 不是内核概念

这是 06 专题反复强调、也最容易搞错的一点：

> **EROFS 内核里没有 "layer（层）" 这个概念。**

容器镜像常说的"分层"是**上层构建/分发的概念**（overlayfs 或镜像格式在处理）。
对 EROFS 内核而言，它看到的只是：

```
一个文件系统 + 若干设备 + 地址指向哪个设备
```

它不知道也不关心"这是第几层"。

⇒ 把 overlayfs 的分层语义套到 EROFS 上会**完全理解错**。

---

## 二、设计理念

#### 理念 1：把"设备号"编进地址高位

一次映射要同时得到两个信息：

- 数据**在设备内的偏移**
- 在**哪个设备**上

常规做法是"地址 + 设备号"两个字段。EROFS 则把它们**压进一个数**：

```
地址 = [ 设备号 (高 16 位) ][ 设备内偏移 (低 48 位) ]
```

由 `sbi->device_id_mask` 指定设备号占多少位（通常是高 16 位）。

**好处**：一次映射得到全部信息，不用再查表。
**代价**：地址可用位数变少（这就是 48-bit 地址特性的由来，见 16 专题）。

#### 理念 2：两种模式，两种地址语义

| | **flatdev（flat 模式）** | **非 flat** |
|---|---|---|
| 地址空间 | 所有设备拼成**一个连续空间** | 每个设备**各自独立** |
| 设备号 | 编在地址高位 | 编在地址高位 |
| 解析方式 | `m_pa += uniaddr` | 按区间查找属于哪个设备 |
| 适用 | 设备可视为一个整体 | 需要逐个定位 |

#### 理念 3：用 idr 表管理额外设备

额外设备数量不定，用 `idr`（整数 ID → 指针）来存：

```c
struct erofs_dev_context {
	struct idr tree;                 /* id → erofs_device_info* */
	struct rw_semaphore rwsem;       /* 保护这张表 */
	unsigned int extra_devices;
	bool flatdev;
};
```

**为什么要 `rwsem`**：设备表在运行时可能被查询（读）也可能变动（写），
用读写信号量让**并发读不互斥**。

---

## 三、实现架构

#### 3.1 对象关系

```
super_block
   └─ s_fs_info → erofs_sb_info
                    ├─ dif0（主设备，内嵌 erofs_device_info）
                    │      └─ file / dax_dev / fsoff / blocks / uniaddr
                    └─ devs → erofs_dev_context
                                 ├─ idr tree ──► erofs_device_info（id 0,1,2…）
                                 ├─ rwsem
                                 ├─ extra_devices
                                 └─ flatdev
```

#### 3.2 映射解析流程

```
erofs_map_blocks() 得到 m_pa + m_deviceid
        │
        ▼
erofs_map_dev(sb, &map)              【data.c】
        │
   ① 默认：填主设备 dif0，m_bdev = sb->s_bdev
        │
   ② 若 m_deviceid != 0（显式指定设备）
        ├ idr_find(devs->tree, m_deviceid - 1)     ← 注意 -1
        ├ 若 flatdev：m_pa += erofs_pos(sb, dif->uniaddr)
        └ 否则：erofs_fill_from_devinfo(map, sb, dif)  换设备
        │
   ③ 若 m_deviceid == 0，但 extra_devices && !flatdev
        └ 遍历 idr，找 m_pa 落在哪个设备的
          [startoff, startoff + blocks) 区间
             ├ 命中：m_pa -= startoff（转成设备内偏移）
             └ 换设备
```

#### 3.3 `erofs_pos()` 是什么

```c
map->m_pa += erofs_pos(sb, dif->uniaddr);
```

`erofs_pos()` 把"块号"转成"字节地址"（乘以块大小）。
`uniaddr` 是设备的**统一地址基址**（以块为单位）。

⇒ flat 模式下，设备内偏移 + 该设备的基址 = 在整个拼合空间里的地址。

---

## 四、关键结构体

#### 4.1 `struct erofs_device_info`（`internal.h`）

```c
struct erofs_device_info {
	char *path;                    /* 设备路径 */
	struct file *file;             /* 文件后端时用（09 专题）*/
	struct dax_device *dax_dev;    /* FSDAX 时用（10 专题）*/
	u64 fsoff, dax_part_off;       /* 本设备内偏移 / DAX 分区偏移 */

	erofs_blk_t blocks;            /* 本设备多少块 */
	erofs_blk_t uniaddr;           /* 统一地址基址（flat 模式用）*/
};
```

⇒ **这个结构体在三个特性里都出现**：多设备（本专题）、文件后端（09）、FSDAX（10）。
理解它就理解了 EROFS 的"设备抽象"。

#### 4.2 `struct erofs_dev_context`（`internal.h`）

见理念 3。`idr tree` + `rwsem` + `extra_devices` + `flatdev`。

#### 4.3 `struct erofs_map_dev`（`internal.h`）

解析结果：

```c
struct erofs_map_dev {
	struct super_block *m_sb;
	struct erofs_device_info *m_dif;    /* ★ 找到的设备信息 */
	struct block_device *m_bdev;        /* 块设备（非 fileio/DAX 时）*/

	erofs_off_t m_pa;                   /* 转成本设备内偏移后的地址 */
	unsigned int m_deviceid;
};
```

#### 4.4 `erofs_sb_info` 中的相关字段

```c
struct erofs_device_info dif0;         /* 主设备，内嵌 */
struct erofs_dev_context *devs;        /* 多设备表 */
u16 device_id_mask;                    /* 设备号占多少位 */
```

---

## 五、主要函数

#### 5.1 `erofs_map_dev()`（`data.c`）—— 核心

三条分支见 3.2。**要点**：

1. **主设备优先**：默认就填 `dif0` 和 `sb->s_bdev`
2. **显式设备号**：`m_deviceid != 0` 时查 idr，注意是 **`m_deviceid - 1`**
   （因为 0 保留给主设备）
3. **隐式推断**：`m_deviceid == 0` 但有额外设备且非 flat 时，
   **遍历所有设备按区间匹配**——这是最慢的一条路

#### 5.2 `erofs_fill_from_devinfo()`（`data.c`）

把某个设备的具体信息填进 `erofs_map_dev`
（`m_dif`、`m_bdev`、以及必要的偏移调整）。

#### 5.3 `erofs_pos()`

块号 → 字节地址的换算（乘块大小）。

---

## 六、来龙去脉：一次跨设备读

```
① 挂载时指定多个设备
     mkfs 侧已把"哪些数据在哪个设备"写进镜像
     内核读入 device table，建好 idr
        │
② 进程读文件
        │
③ erofs_map_blocks()
     └ 得到 m_pa（设备内偏移）+ m_deviceid（设备号，编在地址高位）
        │
④ erofs_map_dev(sb, &map)
     ├ m_deviceid == 0 → 用主设备
     ├ m_deviceid != 0 → idr_find(m_deviceid - 1)
     │     ├ flatdev → m_pa += uniaddr
     │     └ 否则   → 换成该设备的 m_dif / m_bdev
     └ （m_deviceid == 0 但有额外设备）→ 遍历区间匹配
        │
⑤ 拿到 m_dif
     ├ 常规：m_bdev → 走块设备读
     ├ fileio：m_dif->file → 走文件读（09 专题）
     └ DAX：m_dif->dax_dev → 走 DAX（10 专题）
        │
⑥ 数据读出
```

⇒ **多设备逻辑是"后端无关"的**：解析出 `m_dif` 之后，
具体怎么读由后端（bdev / fileio / DAX）决定。

---

## 七、动手验证

#### 验证 1：确认挂载选项

```bash
cd /sdd/linux/linux-stable/fs/erofs
grep -rn "device\|dev=" super.c | grep -i "opt\|param" | head
```

找到多设备挂载选项的解析处（通常是 `device=` 指向一个 blob 文件）。

#### 验证 2：看 sysfs 暴露的 device_table 特性

```bash
# VM 内
mount -t sysfs sysfs /sys
cat /sys/fs/erofs/*/features
```

输出里若含 `device_table`，说明镜像启用了多设备。

#### 验证 3：读源码确认编码方式

```bash
grep -rn "device_id_mask" /sdd/linux/linux-stable/fs/erofs/
```

看它在哪被设置、在哪被使用，验证"设备号编在高位"的说法。

---

## 八、常见误解（重要）

#### 误解 1：EROFS 内核支持"镜像分层（layer）"

**不支持，也没有这个概念**。分层是上层（overlayfs / 镜像格式）的事。
EROFS 只看到"多个设备 + 地址指向哪个设备"。

#### 误解 2：`m_deviceid` 就是 idr 里的 key

差 1。`idr_find(&devs->tree, m_deviceid - 1)` ——
因为 **0 保留给主设备**（`dif0`），额外设备从 1 开始编号。

#### 误解 3：flat 与非 flat 只是实现细节，行为一样

不一样。flat 模式下所有设备共享一个连续地址空间
（`m_pa += uniaddr`）；非 flat 下每个设备独立编址，
需要按区间判断属于哪个设备。

#### 误解 4：多设备会让地址位数变多

相反——设备号**占用了地址的高位**，可用于偏移的位数变少
（这就是 48-bit 地址这个特性的背景，见 16 专题）。

#### 误解 5：设备表查询不需要锁

需要。`devs->rwsem` 保护 idr 表，
`erofs_map_dev()` 里每次查表都 `down_read()` / `up_read()`。

---

## 九、与其他特性的关系

| 特性 | 关系 |
|---|---|
| **文件后端 fileio**（09） | `erofs_device_info.file` —— 每个设备都可以是文件 |
| **FSDAX**（10） | `erofs_device_info.dax_dev` —— 每个设备都可以是 PMEM |
| **48-bit 地址**（16） | 设备号占用高位 ⇒ 偏移位数受限，两者直接相关 |
| **ishare**（11） | 多设备下指纹相同的文件同样可共享页缓存 |
| **xattr**（12） | shared xattr 区也可跨设备 |

---

## 自测检查点

1. 多设备解决什么场景问题？
2. ⚠️ "layer" 是 EROFS 内核的概念吗？
3. `device_id_mask` 是什么？为什么要把设备号编进地址？
4. flatdev 与非 flat 的地址语义有什么区别？
5. `uniaddr` 是什么？flat 模式为什么直接加它？
6. `erofs_map_dev()` 的三条分支分别对应什么情况？
7. 为什么 `idr_find()` 用的是 `m_deviceid - 1`？
8. `erofs_dev_context` 里为什么要 `rwsem`？
9. `erofs_device_info` 在哪些特性里都被用到？
10. 多设备解析出 `m_dif` 之后，具体怎么读由什么决定？

---

## 自测答案

<details>
<summary>点击展开</summary>

1. 一个镜像放不下单个设备；或想把数据/元数据分到不同介质；
   或多个镜像共享基础数据。**本质：一个文件系统跨多个物理设备。**

2. **不是**。分层是上层（overlayfs / 镜像分发格式）的概念。
   EROFS 内核只看到"若干设备 + 地址指向哪个设备"，不知道"第几层"。

3. 指定设备号占地址高多少位（通常高 16 位）。
   把"哪个设备"和"设备内偏移"**压进一个数**，
   一次映射拿到全部信息，不用再查表。

4. **flat**：所有设备拼成一个连续地址空间，地址 = 设备内偏移 + `uniaddr`。
   **非 flat**：每个设备独立编址，要按 `[startoff, startoff+blocks)` 区间
   判断落在哪个设备，再减去 `startoff` 得设备内偏移。

5. `uniaddr` 是设备在**统一地址空间里的基址**（以块为单位）。
   flat 模式下设备被视为连续整体，所以设备内偏移 + 基址 = 全局地址。

6. **①** 默认（主设备 `dif0`）；
   **②** `m_deviceid != 0`：显式指定设备，查 idr；
   **③** `m_deviceid == 0` 但有额外设备且非 flat：遍历区间匹配。

7. 因为 **0 保留给主设备**（`dif0` 不放在 idr 里），
   额外设备从 1 开始编号，所以查表要 `-1`。

8. 设备表会被并发查询（读），也可能变动（写）。
   读写信号量让**并发读不互斥**，提高性能。

9. **多设备**（本专题）、**文件后端 fileio**（用 `file` 字段）、
   **FSDAX**（用 `dax_dev` 字段）。理解它就理解了 EROFS 的设备抽象。

10. 由**后端**决定：`m_bdev`（块设备）→ 常规读；
    `m_dif->file`（文件后端）→ `vfs_iocb_iter_read`；
    `m_dif->dax_dev`（DAX）→ 直接映射。多设备逻辑本身与后端无关。

</details>

---

## 参考
[linux-stable](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)
