---
layout:     post
title:      EROFS 48-bit block address
subtitle:   EROFS 48比特块地址
date:       2026-09-23
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 16 · 特性专题：48-bit 地址

> 特性标志：`EROFS_FEATURE_INCOMPAT_48BIT`（`internal.h`）
> 相关源码：`zmap.c`（越界检查）、`super.c`（读高位字段）、`internal.h`（辅助函数）
> 关键字段：`blocks_hi`、`uniaddr_hi`（on-disk）；`sbi->blkszbits`
>
> 本文回答：**为什么 32 位不够** → **48-bit 装的到底是"字节"还是"块"** →
> **高位字段怎么拼回去** → **内核怎么防越界** → **与多设备的关系**。

## 本专题目标（读完你应该能做到什么）

1. 说清为什么需要突破 32 位的地址限制
2. **纠正一个常见误读**：48-bit 指的是**块地址**位宽，不是字节地址
3. 看懂 `blocks_hi` / `uniaddr_hi` 怎么与低 32 位拼成完整地址
4. 解释 `zmap.c` 里那句越界检查在防什么
5. 说清 48-bit 与**多设备地址编码**（13 专题）的紧张关系
6. 知道这个特性为什么被标为 **incompat**

## 图解

![48-bit 地址：64 位里怎么分，多出来的 16 位装在哪](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-35-48bit-address.svg)

**一句话**：一个 64 位地址被切成两半——**高 16 位放设备号，低 48 位放设备内块地址**；    
48 位这个上限来自 `64 − 16 = 48`。装的是**块地址**，不是字节地址。

自上而下五段 + 底部澄清：

| 段 | 回答什么 | 一句话 |
|---|---|---|
| **① 位布局**（橙/绿） | 64 位怎么分 | `addr \|= (device_id & device_id_mask) << 48`（`data.c`）；反解 `m_deviceid = last >> 48` |
| **② on-disk**（黄） | 镜像里怎么存 | `blocks_lo`(32) + `blocks_hi`(16)、`uniaddr_lo`(32) + `uniaddr_hi`(16) |
| **③ 拼装**（绿） | 内核怎么拼回 | `低 32 位 \| (高 16 位 << 32)`，仅在 `_48bit` 为真时拼；老镜像高位按 0 |
| **④ 容量**（蓝） | 为什么要扩 | 32 位 = 16 TB（不够），48 位 = 1 PB |
| **⑤ 检查**（紫） | 超了怎么办 | `(pend >> blkszbits) >= BIT_ULL(48)` → `-EFSCORRUPTED` |

**⚠️ 底部红框的三件事**：

1. **是块地址，不是字节地址** —— 证据就是那个 `>> blkszbits`；`2^48` **块** × 4 KB = 1 PB。  
   若误读成"字节地址 48 位"，那只有 256 TB，检查逻辑也对不上。
2. **设备号位数是动态的，不是固定 16 位** ——
   `device_id_mask = roundup_pow_of_two(设备数) - 1`（`super.c`），
   设备少则位数少，"高 16 位"只是**上限**。
3. **必须 incompat** —— 老内核不会拼高位，会**地址截断**读到完全错误的位置，
   比拒绝挂载危险得多。

## 一、特性缘由：32 位不够用了

#### 1.1 原始设计：32 位块地址

EROFS 早期用 **32 位**表示块号：

```
32 位块号 × 4 KB 块大小 = 16 TB
```

看起来够大。但两个趋势让它不够：

1. **设备越来越大**——单个 NVMe 已经到几十 TB
2. **多设备聚合**——多个设备拼起来的"统一地址空间"更大

#### 1.2 解决方案：扩到 48 位

```
48 位块号 × 4 KB = 1 PB
```

这够用很久了。

#### 1.3 为什么不直接改结构体？

关键约束：**on-disk 格式必须向后兼容**。

老镜像里那些地址字段就是 32 位的，不能改宽度
（改了老镜像就废了）。

⇒ 做法：**新增两个"高位"字段**（`blocks_hi`、`uniaddr_hi`），
只在启用该特性时才拼上去。

```c
_48bit = erofs_sb_has_48bit(sbi);
...
dif->blocks  = le32_to_cpu(dis->blocks_lo)
             | (_48bit ? (u64)le16_to_cpu(dis->blocks_hi) << 32 : 0);
dif->uniaddr = le32_to_cpu(dis->uniaddr_lo)
             | (_48bit ? (u64)le16_to_cpu(dis->uniaddr_hi) << 32 : 0);
```
⇒ **老镜像（无该特性）高位为 0，行为不变**；新镜像才有有效高位。这是典型的"渐进扩展"设计。

## 二、设计理念

#### 理念 1：⚠️ 48-bit 是**块地址**，不是字节地址

这是最容易搞错的一点。看内核的检查：

```c
/* Filesystems beyond 48-bit physical block addresses are invalid */
if (unlikely(check_add_overflow(map->m_pa, map->m_plen, &pend) ||
             (pend >> sbi->blkszbits) >= BIT_ULL(48)))
        return -EFSCORRUPTED;
```

注意 `(pend >> sbi->blkszbits)`：

- `pend` 是**字节**地址
- 右移 `blkszbits`（如 12，即除以 4096）后得到**块号**
- 再与 `BIT_ULL(48)` 比较

⇒ **限制的是"块号不超过 48 位"**。

换算成字节容量：`2^48 块 × 4 KB = 2^60 字节 = 1 PB`。

（若误读成"字节地址 48 位"，那只有 256 TB，且检查逻辑也对不上。）

#### 理念 2：与多设备共享同一个 64 位空间

回想 13 专题：**设备号编在地址高位**。

```
64 位地址 = [ 设备号 ][ 设备内偏移 ]
```

而 48-bit 特性说的是"物理块地址不超过 48 位"——
两者在同一个 64 位数里**争抢位数**：

| 用途 | 占用 |
|---|---|
| 设备号 | 高位，**最多 16 位**（位数动态，见下） |
| 设备内偏移（块地址） | 低 48 位 |

⇒ 这解释了为什么是 **48** 而不是别的数：给设备号留够 16 位后，剩下就是 48 位。

⚠️ **设备号实际占几位是算出来的，不是固定 16**：

```c
/* super.c，扫描设备表时 */
sbi->device_id_mask = roundup_pow_of_two(ondisk_extradevs + 1) - 1;
```

| 设备数 | mask | 设备号位数 |
|---|---|---|
| 1 | 0 | 0（不需要） |
| 2 | 1 | 1 |
| 5 | 7 | 3 |

⇒ 只有设备多到需要 16 位时才占满；**「高 16 位」是上限**。编码在 `data.c` 的 chunk 映射路径里：  
`addr |= (u64)(device_id & device_id_mask) << 48;`，反解是 `m_deviceid = last >> 48`。

#### 理念 3：用 incompat 兜底

```c
EROFS_FEATURE_FUNCS(48bit, incompat, INCOMPAT_48BIT)
```

**incompat**：不认识该特性的内核**拒绝挂载**。

为什么必须 incompat：老内核不知道要拼 `blocks_hi`，
会只读低 32 位——**地址截断**，读到完全错误的位置。  
这比"挂载失败"危险得多，所以必须强拒。

## 三、实现架构

#### 3.1 on-disk 布局：低位 + 高位

```c
struct erofs_deviceslot（on-disk，erofs_fs.h）
   ├─ blocks_lo   : __le32    ← 总块数低 32 位（老内核也读）
   ├─ uniaddr_lo  : __le32    ← 统一起始块低 32 位
   ├─ blocks_hi   : __le16    ← 总块数高 16 位（仅 48bit 时有效）
   └─ uniaddr_hi  : __le16    ← 统一起始块高 16 位
```

拼装（挂载时，`super.c`）：

```
完整值 = 低 32 位 | (高 16 位 << 32)      // 共 48 位
```

**superblock 里还有一处同款复用**：  
48BIT 开启时，`union rb` 中的 **`rootnid_2b` 被改当 `blocks_hi` 用**
（因为此时 root nid 改用 8 字节的 `rootnid_8b`）。  
这也是"不动结构、只复用字段"的思路。

#### 3.2 内核读路径

```
① 挂载
     ├ _48bit = erofs_sb_has_48bit(sbi)
     └ 解析 device slot 时拼上 blocks_hi / uniaddr_hi
        │
② 读文件
     └ erofs_map_blocks() 得到 m_pa
        │
③ zmap.c 的越界检查
     ├ pend = m_pa + m_plen
     ├ 若加法溢出 → -EFSCORRUPTED
     └ 若 (pend >> blkszbits) >= 2^48 → -EFSCORRUPTED
```

#### 3.3 越界检查的意义

```c
if (unlikely(check_add_overflow(map->m_pa, map->m_plen, &pend) ||
             (pend >> sbi->blkszbits) >= BIT_ULL(48)))
        return -EFSCORRUPTED;
```

两道保险：

1. **`check_add_overflow`**：`m_pa + m_plen` 溢出 ⇒ 镜像数据不自洽
2. **块号 ≥ 2^48** ⇒ 超出可表示范围

⇒ 都是**镜像损坏**的信号，所以返回 `-EFSCORRUPTED`（而不是别的错误码）。

**为什么要在解压路径查？**  
因为压缩文件的 `m_pa` 直接来自镜像的 extent 数据，恶意/损坏的镜像可能填一个荒谬的大值。  
在这里拦住，避免后续用它去读设备时越界。

## 四、关键结构体与字段

#### 4.1 on-disk 设备槽（`erofs_fs.h`）

| 字段 | 位宽 | 说明 |
|---|---|---|
| `blocks_lo` | 32 | 设备总块数（低 32 位） |
| `blocks_hi` | 16 | 块数高 16 位（48bit 特性） |
| `uniaddr_lo` | 32 | 统一地址基址（低 32 位） |
| `uniaddr_hi` | 16 | 基址高 16 位（48bit 特性） |

（另见 3.1：superblock 的 `union rb` 在 48BIT 开启时把 `rootnid_2b` 复用为 `blocks_hi`。）

### 4.2 `erofs_sb_info`（`internal.h`）

```c
u32 feature_incompat;      /* INCOMPAT_48BIT 位 */
unsigned char blkszbits;   /* 块大小位移，用于字节↔块换算 */
```

#### 4.3 辅助函数（`internal.h`）

```c
EROFS_FEATURE_FUNCS(48bit, incompat, INCOMPAT_48BIT)
```

展开出 `erofs_sb_has_48bit(sbi)` 等。

#### 4.4 sysfs 暴露（`sysfs.c`）

```c
EROFS_ATTR_FEATURE(48bit);
```

## 五、主要函数 / 代码位置

按"**认特性 → 拼地址 → 分位宽 → 编码 → 防越界**"五个环节串起来：

| 环节 | 位置 | 做什么 |
|---|---|---|
| ① 认特性 | `internal.h` / `super.c` | `erofs_sb_has_48bit()` 判断镜像是否开了 48BIT |
| ② 拼地址 | `super.c`： `erofs_init_device()` | 把 `blocks_lo` + `blocks_hi` 拼成完整 48 位值 |
| ③ 定位宽 | `super.c`： `erofs_scan_devices()` | 算 `device_id_mask`，决定设备号占几位 |
| ④ 编码 | `data.c` | 设备号 `<< 48` 塞进高 16 位；`>> 48` 取回 |
| ⑤ 防越界 | `zmap.c` | 块号 ≥ 2^48 就 `-EFSCORRUPTED` |

#### 5.1 `internal.h`：字节 ↔ 块的两个换算宏

理解 48-bit 的钥匙在这两个宏：

```c
#define erofs_blknr(sb, pos)	((erofs_blk_t)((pos) >> (sb)->s_blocksize_bits))
#define erofs_pos(sb, blk)	((erofs_off_t)(blk) << (sb)->s_blocksize_bits)
```

- `erofs_pos()`：**块号 → 字节**（左移 `blkszbits`）
- `erofs_blknr()`：**字节 → 块号**（右移 `blkszbits`）

`s_blocksize_bits` 就是 `sbi->blkszbits`（块大小位移，4KB 时 = 12）。

⇒ 记住这两个宏，"48-bit 是**块地址**不是字节地址"这句就不会理解错——
凡是跟 48 比大小的地方，都要先经 `>> blkszbits` 把字节换成块号（见 5.6）。

#### 5.2 `internal.h` / `super.c`：认不认这个特性

辅助函数由宏生成（`internal.h`）：

```c
EROFS_FEATURE_FUNCS(48bit, incompat, INCOMPAT_48BIT)
```

展开出 `erofs_sb_has_48bit(sbi)` 等。注意它是 **incompat**：  
不认识该特性的内核**拒绝挂载**，由挂载路径的通用特性检查完成，不需要某个具体函数去调用它。

为什么必须 incompat：老内核不知道要拼 `blocks_hi`，只会读低 32 位
⇒ **地址截断、读到完全错误的位置**，比拒绝挂载危险得多。

#### 5.3 `super.c`：把 48 位拼回去（`erofs_init_device()`）

这是本专题最核心的一段。设备表里每个设备都这样拼：

```c
_48bit = erofs_sb_has_48bit(sbi);
dif->blocks = le32_to_cpu(dis->blocks_lo) |
	(_48bit ? (u64)le16_to_cpu(dis->blocks_hi) << 32 : 0);
dif->uniaddr = le32_to_cpu(dis->uniaddr_lo) |
	(_48bit ? (u64)le16_to_cpu(dis->uniaddr_hi) << 32 : 0);
sbi->total_blocks += dif->blocks;
```

三个要点：

1. **字段名是 `blocks_lo` / `uniaddr_lo`**（带 `_lo`），
   高 16 位才是 `blocks_hi` / `uniaddr_hi`。
2. **`_48bit` 为假时高位按 0 处理** —— 老镜像行为完全不变，这就是"渐进扩展"：  
  不动老字段宽度，只新增字段 + 一个 feature 位。
3. 拼出来的 `dif->blocks` 会累加到 `sbi->total_blocks`，
   供后续（如 `statfs`、容量计算）使用。

同一个函数里还处理了额外设备怎么打开：

```c
if (!sbi->devs->flatdev && !dif->path) {
	if (!dis->tag[0]) {
		erofs_err(sb, "empty device tag @ pos %llu", *pos);
		return -EINVAL;
	}
	dif->path = kmemdup_nul(dis->tag, sizeof(dis->tag), GFP_KERNEL);
	...
```

⇒ 挂载时**没给** `-o device=` 的话，就用 device slot 里的 `tag`（64 字节摘要）
当路径去开设备。  
13 专题里我们显式给了 `device=/dev/vdc`，走的是另一条路。

### 5.4 `super.c`：设备号到底占几位（`erofs_scan_devices()`）

"64 位地址 = 高 16 位设备号 + 低 48 位块地址"这个分配不是写死的，是**算出来的**：

```c
ondisk_extradevs = le16_to_cpu(dsb->extra_devices);

if (sbi->devs->extra_devices &&
    ondisk_extradevs != sbi->devs->extra_devices) {
	erofs_err(sb, "extra devices mismatch (ondisk %u, given %u)",
		  ondisk_extradevs, sbi->devs->extra_devices);
	return -EINVAL;
}
...
if (!ondisk_extradevs)
	return 0;
if (!sbi->devs->extra_devices)
	sbi->devs->flatdev = true;

sbi->device_id_mask = roundup_pow_of_two(ondisk_extradevs + 1) - 1;
```

三个要点：

1. **数量必须对齐**：镜像里记的 `extra_devices` 与挂载时给的 `device=` 个数
   不一致直接 `-EINVAL`。
2. **flatdev**：不给额外设备但镜像里有 → 视为"扁平设备"（多个设备拼成的
   一段连续空间），不需要逐个打开。
3. **`device_id_mask` 随设备数变化**：

| 设备数 | mask | 设备号位数 |
|---|---|---|
| 1（无额外设备） | 0 | 0 |
| 2 | 1 | 1 |
| 3~4 | 3 | 2 |
| 5~8 | 7 | 3 |
| … | … | … |

⇒ 只有设备多到需要 16 位时才占满高 16 位；**「高 16 位」是上限，不是固定值**。  
剩下的位给块地址，最多 64 − 16 = **48**——这就是 48 这个数字的来历。

#### 5.5 `data.c`：64 位地址里怎么塞设备号

chunk-based 文件（13 专题的多设备镜像就是这种）在映射时做编解码：

```c
addr = (((u64)le16_to_cpu(idx[nr].startblk_hi) << 32) |
	le32_to_cpu(idx[nr].startblk_lo)) & addrmask;
if (addr ^ (EROFS_NULL_ADDR & addrmask))
	addr |= (u64)(le16_to_cpu(idx[nr].device_id) &
		EROFS_SB(sb)->device_id_mask) << 48;
else
	addr = EROFS_NULL_ADDR;
```

拆开看：

- 低 48 位 = 设备内块地址（`startblk_hi << 32 | startblk_lo`），
  再 `& addrmask` 把设备号位清掉
- 高 16 位 = `(device_id & device_id_mask) << 48`

取用时反着来：

```c
if (last != EROFS_NULL_ADDR) {
	map->m_pa = erofs_pos(sb, last & addrmask) - map->m_llen;
	map->m_deviceid = last >> 48;
	map->m_flags = EROFS_MAP_MAPPED;
}
```

- `last & addrmask` 取回块号 → `erofs_pos()` 换成字节地址
- `last >> 48` 取回设备号

⇒ **一个 64 位数同时装了"在哪个设备"和"设备内哪一块"**，
这就是 5.4 里那个 mask 的用处。

#### 5.6 `zmap.c`：越界检查（这里是"块号"不是"字节"）

压缩映射路径上的两道保险：

```c
/* Filesystems beyond 48-bit physical block addresses are invalid */
if (unlikely(check_add_overflow(map->m_pa, map->m_plen, &pend) ||
	     (pend >> sbi->blkszbits) >= BIT_ULL(48)))
	return -EFSCORRUPTED;
```

1. `check_add_overflow(m_pa, m_plen, &pend)` —— 加法溢出说明镜像数据不自洽
2. `(pend >> sbi->blkszbits) >= BIT_ULL(48)` —— **先右移 `blkszbits` 转成块号**，
   再和 2^48 比

⇒ 注意那个 `>> sbi->blkszbits`：这是"48-bit 指的是**块地址**"的直接证据。
若误读成"字节地址 48 位"，容量只有 256 TB，而且这里根本不该右移。

为什么放在解压路径：压缩文件的 `m_pa` **直接来自镜像 extent**，
损坏/恶意镜像可以填荒谬的大值，在这里拦住才不会拿着越界地址去读设备。
返回 `-EFSCORRUPTED`（镜像损坏），不是别的错误码。

#### 5.7 `sysfs.c`：只做暴露

```c
EROFS_ATTR_FEATURE(48bit);
```

把 `48bit` 这个名字显示到 `/sys/fs/erofs/<dev>/features`，方便运维确认。
它不参与任何判断逻辑。

## 六、来龙去脉：完整串一遍

```
① mkfs 造一个大/多设备镜像
     ├ 发现块数或统一地址超过 32 位
     ├ 把高 16 位写进 blocks_hi / uniaddr_hi
     └ 在 superblock 打上 INCOMPAT_48BIT
        │
② 挂载
     ├ 老内核：不认 INCOMPAT_48BIT → 拒绝挂载 ✓（安全）
     └ 新内核：_48bit = true → 拼装完整 48 位值
        │
③ 读文件
     └ m_pa 是完整的 48 位块地址（字节形式）
        │
④ 越界检查（zmap.c）
     ├ 加法溢出？      → -EFSCORRUPTED
     └ 块号 ≥ 2^48？   → -EFSCORRUPTED
        │
⑤ 正常继续
```

## 七、动手验证

#### 验证 1：看特性定义

```bash
cd /sdd/linux/linux-stable/fs/erofs
grep -rn "48bit\|48BIT" .
```

会看到 feature 宏、sysfs 暴露、以及 `super.c` 的高位拼装。

#### 验证 2：看越界检查的确切写法

```bash
cd /sdd/linux/linux-stable/fs/erofs
grep -n -A3 "48-bit physical block" zmap.c
```

确认是 `(pend >> sbi->blkszbits) >= BIT_ULL(48)` ——
**注意右移 blkszbits**，这是"块地址而非字节地址"的直接证据。

### 验证 3：看高位字段怎么拼

```bash
grep -n "blocks_hi\|uniaddr_hi" /sdd/linux/linux-stable/fs/erofs/super.c
```

确认 `_48bit ? (u64)le16_to_cpu(...) << 32 : 0` 的写法。

#### 验证 4：VM 里看 feature

```bash
mount -t sysfs sysfs /sys
mount -t erofs /host/comp2.erofs /mnt
cat /sys/fs/erofs/*/features
```

## 八、常见误解（重要）

#### 误解 1：48-bit 指"字节地址 48 位"

**不对**。是**块地址** 48 位。

证据：`(pend >> sbi->blkszbits) >= BIT_ULL(48)` ——
先把字节地址右移 `blkszbits` 转成块号，再比较。

容量换算：`2^48 块 × 块大小`（4 KB 时 = 1 PB）。

#### 误解 2：48 这个数字是随便定的

不是。它与**多设备的设备号编码**直接相关：
64 位地址里要给设备号留出位置，最多留 16 位，剩下 **48 位**给设备内偏移。

（补充：设备号实际位数由 `device_id_mask = roundup_pow_of_two(设备数) - 1` 动态决定，
"16 位"是上限而非固定值——见理念 2。）

#### 误解 3：老内核能读 48-bit 镜像（只是高位丢了）

**不能挂载**。该特性是 **incompat**，
不认识的内核会**直接拒绝**。

（如果真让它读了，高位丢失 ⇒ 地址截断 ⇒ 读到错误位置，
比拒绝危险得多——这正是标 incompat 的原因。）

#### 误解 4：只有超大单设备才用得上

多设备聚合也会让"统一地址空间"超过 32 位，
所以**多设备场景同样依赖**这个特性。

#### 误解 5：越界只是理论问题

压缩文件的 `m_pa` 直接来自镜像 extent 数据，
损坏/恶意镜像可以填荒谬值。
`zmap.c` 的检查就是为了拦住这种情况（返回 `-EFSCORRUPTED`）。

## 九、与其他特性的关系

| 特性 | 关系 |
|---|---|
| **多设备**（13 专题） | **最直接**——设备号占高位（最多 16 位，位数动态），剩余 48 位给偏移，两者共享同一个 64 位数 |
| **压缩**（04） | 越界检查在 `zmap.c`（压缩映射路径） |
| **fileio / FSDAX**（09/10） | `erofs_map_dev` 后仍有偏移概念，48-bit 影响地址有效范围 |
| **incompat 特性体系** | 与 dedupe 同属 incompat，都是"不认识就拒挂" |

> 📌 顺带说明：这个特性的**语义**（incompat 还是别的、检查是否完备）
> 曾在全量分析中被列为待上游确认的问题（编号 A5），
> 详见 `erofs-analysis/` 下的相关文档。本文档只描述**当前代码的实际行为**。

## 自测检查点

1. 为什么需要突破 32 位块地址？
2. ⚠️ 48-bit 指的是字节地址还是块地址？证据是什么？
3. `blocks_hi` / `uniaddr_hi` 的作用？老镜像里它们的值如何？
4. 为什么用"新增高位字段"而不是改原字段宽度？
5. 48 这个数字与多设备有什么关系？
6. 为什么该特性是 incompat？
7. `zmap.c` 的越界检查做了哪两件事？返回什么错误码？
8. 为什么在压缩路径（而非别处）做这个检查？
9. 4 KB 块大小下，48 位块地址对应多大容量？
10. 多设备聚合为什么也会需要 48-bit？

## 自测答案

<details>
<summary>点击展开</summary>

1. 32 位块号 × 4 KB = 16 TB。
   单个设备越来越大（几十 TB 的 NVMe），且多设备聚合后
   "统一地址空间"更大，16 TB 不够用了。

2. **块地址**。证据是 `(pend >> sbi->blkszbits) >= BIT_ULL(48)`
   ——先把字节地址右移 `blkszbits` 换算成块号，再与 `2^48` 比较。

3. 存 `blocks` / `uniaddr` 的**高 16 位**，与低 32 位拼成 48 位。
   老镜像（无该特性）时按 0 处理，行为不变。

4. **on-disk 向后兼容**：老镜像的地址字段就是 32 位宽，
   改宽度会让老镜像作废。新增字段是"渐进扩展"的标准做法。

5. 64 位地址里要给**设备号**留位置，最多 16 位，
   剩下 64 − 16 = **48 位**给设备内偏移。所以是 48 而非其他数字。
   （设备号实际位数由 `device_id_mask = roundup_pow_of_two(设备数) - 1` 动态决定，
   16 位是上限。）

6. 老内核不知道要拼 `blocks_hi`，只会读低 32 位 ⇒
   **地址截断、读到错误位置**。这比拒绝挂载危险得多，
   所以必须 incompat（不认识就拒挂）。

7. **①** `check_add_overflow(m_pa, m_plen, &pend)` 检查加法溢出；
   **②** `(pend >> blkszbits) >= BIT_ULL(48)` 检查块号越界。
   两者都返回 **`-EFSCORRUPTED`**（镜像损坏）。

8. 因为压缩文件的 `m_pa` **直接来自镜像的 extent 数据**，
   损坏/恶意镜像可能填荒谬的大值；在这里拦住可避免后续用越界地址读设备。

9. `2^48 块 × 4 KB = 2^48 × 2^12 = 2^60 字节 = 1 PB`。

10. 多设备会把所有设备拼成**一个连续统一地址空间**，
    聚合后的总块数可能远超 32 位表示范围，所以需要 48 位。

</details>

## 参考
[linux-stable](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)
