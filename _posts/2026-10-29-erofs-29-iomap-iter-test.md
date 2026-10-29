---
layout:     post
title:      EROFS iomap iter test
subtitle:   EROFS iomap 迭代数值的实测验证
date:       2026-10-29
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
---

# 29 · iomap 迭代数值的实测验证

> **目的**：把此前「iomap_iter 三轮迭代」的源码分析与构造示例，用**运行时真实数字**验证一遍。  
> **内核基线**：`a804c5742bff`（`7.3.0-01703-ga804c5742bff`，本机构建 #23）  
> **方法**：在 `fs/iomap/` 与 `fs/erofs/` 的 5 个关键位置插 `pr_info`，  
> 重建内核，在 QEMU 虚拟机里挂载 EROFS 镜像读文件，从 dmesg 抓 `IOMAPDBG` 前缀的输出。  
> **结论摘要**：推进规则、空洞不计提交。  
> 但本次页缓存分配到的都是 order-0（4K）folio，**大 folio / ifs 分支未被触发**，  
> 因此之前 16K-folio 那一版示例属于构造值，本报告已标注清楚。

---

## 1. 实验环境

| 项       | 值                                                                                                                      |
| -------- | ----------------------------------------------------------------------------------------------------------------------- |
| 源码树   | `/home/linux/erofs/linux-stable`（HEAD = `a804c5742bff`）                                                                      |
| 内核版本 | `7.3.0-01703-ga804c5742bff`                                                                                             |
| 相关配置 | `CONFIG_FS_IOMAP=y`、`CONFIG_EROFS_FS=y`、`CONFIG_EROFS_FS_ZIP=y`、`CONFIG_EROFS_FS_BACKED_BY_FILE=y`、`CONFIG_9P_FS=y` |
| 虚拟机   | `qemu-system-x86_64 -m 8192 -smp 4 --enable-kvm`，根文件系统 `erofs-rootfs-ext4.img`                                    |
| 镜像工具 | erofs-utils 1.9.4（`utils-x8664/`）                                                                                     |
| 实测日志 | `/home/linux/erofs/iomap-dbg/vm.log`、`dbg.txt`（首轮）、`dbg2.txt`（第二轮，含计数器）                                        |
| 补丁文件 | `/home/linux/erofs/iomap-dbg/debug.patch`                                                                                      |

---

## 2. 注入的调试打印（共 7 处）

| 位置                                               | 打印前缀                      | 观测对象                                                                |
| -------------------------------------------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `fs/iomap/iter.c` `iomap_iter()`                   | `iter_enter`                  | 每轮开始：`pos`/`len`/`iter_start_pos` + 本轮 `iomap` 的全部字段        |
| `fs/iomap/iter.c` `iomap_iter()`                   | `iter_exit`                   | 迭代终止那一次：`ret` 与最终 `pos`/`len`，以及 `iomap` **是否还留着值** |
| `fs/erofs/data.c` `erofs_iomap_begin()` 空洞分支   | `e_begin ... HOLE`            | EROFS 侧的 `m_la`/`m_llen`/`m_flags` → `IOMAP_HOLE`                     |
| `fs/erofs/data.c` `erofs_iomap_begin()` 结尾       | `e_begin ... type=`           | `m_pa` → `IOMAP_MAPPED` / `IOMAP_INLINE`，含 `bdev`、`deviceid`         |
| `fs/iomap/buffered-io.c` `iomap_read_folio_iter()` | `rf_iter`                     | 每段 range 的 `poff`/`plen`/`type`（处理前）                            |
| `fs/iomap/buffered-io.c` `iomap_read_folio_iter()` | `rf_done`                     | 处理完的 `submitted` 累计值                                             |
| `fs/iomap/buffered-io.c` `iomap_read_end()`        | `read_end` / `read_end_noifs` | 收尾账：`bytes_submitted`、`read_bytes_pending`                         |

> 打印用 `pr_info` 而非 `pr_debug`/dyndbg，是为了在 dmesg 里一次拿到全部数字。  

---

## 3. 测试镜像的构造

用 `--chunksize=4096` 生成 chunk-based 布局，并特意留一个空洞：

```
sparse16k : 16384 字节；[0,4K) 有数据、[4K,8K) 空洞、[8K,16K) 有数据
tiny23    : 24 字节（tailpacking inline）
mid5000   : 5000 字节
big1m     : 1048576 字节
```

`dump.erofs --path=/sparse16k -e chunk.erofs` 的实测输出（**空洞被如实记录**）：

```
NID: 46   Links: 1   Layout: 4   Compression ratio: 100.00%
 Ext:   logical offset   |  length :     physical offset    |  length
   0:        0..    4096 |    4096 :    1060864..   1064960 |    4096
   1:     4096..    8192 |    4096 : 17592186040320..17592186044416 |    4096
   2:     8192..   12288 |    4096 :    1064960..   1069056 |    4096
   3:    12288..   16384 |    4096 :    1069056..   1073152 |    4096
```

第 1 项的物理块号 = `17592186040320 / 4096 = 4294967295 = 0xFFFFFFFF`，  
即 `EROFS_NULL_ADDR`，**这个 chunk 就是空洞**。  
而第 2、3 项的物理块相邻（1064960 + 4096 = 1069056），正好可以被 `erofs_map_chunks()` 合并成一个 8192 的映射。

> Layout 编号对照：`FLAT_PLAIN=0`、`FLAT_INLINE=2`、`CHUNK_BASED=4`。

---

## 4. 实测结果

[完整log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-10-29-erofs-29-iomap-iter-vm.log)  
[debug patch](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-10-29-erofs-29-iomap-debug.patch)

### 4.1 主案例：`sparse16k`（i_ino=46）——三轮迭代

`cat /mnt/c/sparse16k > /dev/null` 抓到的完整序列（时间戳已去掉）：

```
e_begin:   ino=46 la=0    llen=4096 mflags=0x1 pa=103000 -> type=2 addr=103000 bdev=1 devid=0
iter_enter: ino=46 pos=0    len=16384 start=0    | iomap off=0    len=4096 type=2 addr=103000 flags=0x0 src=0
rf_iter:   ino=46 fpos=0    fsize=4096 pos=0    type=2 poff=0 plen=4096 submitted=0
rf_done:   ino=46 fpos=0    type=2 poff=0 plen=4096 submitted=4096

e_begin:   ino=46 la=4096 llen=4096 mflags=0x0 -> HOLE addr=ffffffffffffffff devid=0
iter_enter: ino=46 pos=4096 len=12288 start=4096 | iomap off=4096 len=4096 type=0 addr=ffffffffffffffff flags=0x0 src=0
rf_iter:   ino=46 fpos=4096 fsize=4096 pos=4096 type=0 poff=0 plen=4096 submitted=0
rf_done:   ino=46 fpos=4096 type=0 poff=0 plen=4096 submitted=0

e_begin:   ino=46 la=8192 llen=8192 mflags=0x1 pa=104000 -> type=2 addr=104000 bdev=1 devid=0
iter_enter: ino=46 pos=8192 len=8192 start=8192 | iomap off=8192 len=8192 type=2 addr=104000 flags=0x0 src=0
rf_iter:   ino=46 fpos=8192  fsize=4096 pos=8192  type=2 poff=0 plen=4096 submitted=0
rf_done:   ino=46 fpos=8192  type=2 poff=0 plen=4096 submitted=4096
rf_iter:   ino=46 fpos=12288 fsize=4096 pos=12288 type=2 poff=0 plen=4096 submitted=0
rf_done:   ino=46 fpos=12288 type=2 poff=0 plen=4096 submitted=4096

iter_exit: ino=46 ret=0 pos=16384 len=0 start=8192 | iomap off=8192 len=8192 type=2 addr=104000
```

整理成表（`type` 取值：`0=HOLE`、`2=MAPPED`、`4=INLINE`）：

| 阶段              | `pos`     | `len` | `iter_start_pos` | `iomap.offset` | `iomap.length` | type  | `iomap.addr`         |
| ----------------- | --------- | ----- | ---------------- | -------------- | -------------- | ----- | -------------------- |
| 入口（构造 iter） | 0         | 16384 | 0                | —              | 0（全 0）      | —     | —                    |
| ① 进入            | 0         | 16384 | 0                | 0              | 4096           | 2     | `0x103000`           |
| ① 结束            | 4096      | 12288 | 0                | 0              | 4096           | 2     | `0x103000`           |
| ② 进入            | 4096      | 12288 | 4096             | 4096           | 4096           | 0     | `0xffffffffffffffff` |
| ② 结束            | 8192      | 8192  | 4096             | 4096           | 4096           | 0     | `0xffffffffffffffff` |
| ③ 进入            | 8192      | 8192  | 8192             | 8192           | 8192           | 2     | `0x104000`           |
| ③ 结束            | 16384     | 0     | 8192             | 8192           | 8192           | 2     | `0x104000`           |
| **出口**          | **16384** | **0** | **8192**         | **8192**       | **8192**       | **2** | **`0x104000`**       |

三个可以直接读出来的事实：

1. **推进量 = 各轮 iomap 的长度**：4096 + 4096 + 8192 = 16384，  
   `len` 正好归零。  
2. **`iter_start_pos` 只在 `iomap_iter_done()` 里被改写**，  
   出口时停在最后一轮的 8192。  
3. **出口时 `iomap` 仍保留第 ③ 轮的值**（`off=8192 len=8192 type=2 addr=104000`）——  
   因为 `iomap_iter_continue()` 在 `ret<=0` 时**提前 return，  
   `memset` 在它后面**。

### 4.2 计数器证据：空洞确实不计入 `bytes_submitted`

```
rf_done: ino=46 fpos=0     type=2 poff=0 plen=4096 submitted=4096   ← MAPPED，提交
rf_done: ino=46 fpos=4096  type=0 poff=0 plen=4096 submitted=0      ← HOLE，零填，不提交
rf_done: ino=46 fpos=8192  type=2 poff=0 plen=4096 submitted=4096   ← MAPPED，提交
rf_done: ino=46 fpos=12288 type=2 poff=0 plen=4096 submitted=4096   ← MAPPED，提交
```

整轮运行 452 条调试行里，`rf_done` 的统计**没有一条例外**：

| type        | `submitted`    | 行数 |
| ----------- | -------------- | ---- |
| 2（MAPPED） | 4096（= plen） | 178  |
| 0（HOLE）   | 0              | 8    |

空洞那一页的收尾走的是无 ifs 分支：

```
read_end_noifs: ino=46 fpos=4096 fsize=4096 submitted=0
```

即 `iomap_read_end()` 拿着 `bytes_submitted=0` 进来，  
`WARN_ON_ONCE(bytes_submitted)` 没有触发，直接 `folio_unlock()`——与代码一致。

### 4.3 `tiny23`（i_ino=42）：tailpacking 内联 → `IOMAP_INLINE`

```
e_begin:    ino=42 la=0  llen=24   mflags=0x3 pa=560 -> type=4 addr=560 bdev=1 devid=0
iter_enter: ino=42 pos=0 len=4096 start=0 | iomap off=0 len=24 type=4 addr=560 flags=0x0 src=0
e_begin:    ino=42 la=24 llen=4072 mflags=0x0 -> HOLE addr=ffffffffffffffff devid=0
iter_enter: ino=42 pos=24 len=4072 start=24 | iomap off=24 len=4072 type=0 addr=ffffffffffffffff flags=0x0 src=0
rf_iter:    ino=42 fpos=0 fsize=4096 pos=24 type=0 poff=24 plen=4072 submitted=0
iter_exit:  ino=42 ret=0 pos=4096 len=0 start=24 | iomap off=24 len=4072 type=0 addr=ffffffffffffffff
```

两点值得注意：

* `EROFS_MAP_META`（`mflags=0x3`）被翻译成 `type=4 = IOMAP_INLINE`，  
  `addr=0x560` 是**元数据块**地址（不是普通数据块）。  
* **INLINE 那一轮没有 `rf_iter` 打印**——  
  因为 `iomap_read_folio_iter()` 在函数最前面就 `return iomap_iter_advance(iter, length)`，  
  走的是 `iomap_read_inline_data()` 快速路径，根本到不了我打点的位置。  
  这本身就是「INLINE 有独立分支」的证据。  
* 第 2 轮把 folio 尾部 4072 字节映射成 HOLE 并零填——  
  **post-EOF 零填充**的实测证据。

### 4.4 `big1m`（i_ino=40）：一次映射覆盖多个 folio + `iomap_length` 的裁剪

```
e_begin:    ino=40 la=0 llen=1048576 mflags=0x1 pa=1000 -> type=2 addr=1000 bdev=1 devid=0
iter_enter: ino=40 pos=0 len=16384 start=0 | iomap off=0 len=1048576 type=2 addr=1000 flags=0x0 src=0
rf_iter:    ino=40 fpos=0     ... type=2 poff=0 plen=4096
rf_iter:    ino=40 fpos=4096  ... type=2 poff=0 plen=4096
rf_iter:    ino=40 fpos=8192  ... type=2 poff=0 plen=4096
rf_iter:    ino=40 fpos=12288 ... type=2 poff=0 plen=4096
iter_exit:  ino=40 ret=0 pos=16384 len=0 start=0 | iomap off=0 len=1048576 type=2 addr=1000
```

`iomap.length = 1048576`，但 `iter.len = 16384`——  
**`iomap_length()` 的 `min(len, end - pos)` 裁剪被直接观测到**：  
一次 begin 产出 1M 的映射，本轮只用掉 16384，剩下留到下一轮（`iter_start_pos` 仍是 0，  
因为中间没有再迭代）。

### 4.5 全局统计

| 指标                       | 实测值                                     |
| -------------------------- | ------------------------------------------ |
| 调试行总数（第二轮）       | 452（含 `dmesg` 回显重复，实际事件约一半） |
| `iter_enter` / `iter_exit` | 28 / 18                                    |
| `e_begin`                  | 26                                         |
| `rf_iter` / `rf_done`      | 186 / 186                                  |
| folio 尺寸分布             | **全是 4096**（186/186），无大 folio       |
| `read_end`（ifs 分支）     | **0 次**                                   |
| `read_end_noifs`           | 有输出，见 4.2                             |

---

## 5. 与源码分析的逐条对照

| 分析结论                                                              | 实测结果                                                                                       | 判定                 |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------- |
| `pos` 累加、`len` 递减，推进量 = 本轮映射长度                         | 0→4096→8192→16384；len 16384→0                                                                 | ✅ 证实               |
| `iter_start_pos` 每轮由 `iomap_iter_done()` 更新                      | 0 → 4096 → 8192                                                                                | ✅ 证实               |
| **空洞不计入 `bytes_submitted`**                                      | type=0 的 8 条 `rf_done` 全为 0；type=2 的 178 条全为 4096                                     | ✅ 证实（零例外）     |
| EROFS 侧 `iomap->flags` 恒为 0                                        | 所有 `iter_enter` 都是 `flags=0x0`                                                             | ✅ 证实               |
| EROFS 从不填 `srcmap`，`iomap_iter_srcmap()` 恒返回 dstmap            | 所有 `src=0`                                                                                   | ✅ 证实               |
| `erofs_map_chunks()` 合并物理连续的 chunk                             | `la=8192 llen=8192`（两个 4K chunk 合并）                                                      | ✅ 证实               |
| `EROFS_MAP_META` → `IOMAP_INLINE`，且走独立快速路径                   | type=4；该轮无 `rf_iter`                                                                       | ✅ 证实               |
| 空洞 / 超 i_size → 零填充                                             | `plen=4072` 的零填、`plen=4096` 的 HOLE 页                                                     | ✅ 证实               |
| `iomap_length()` 做 `min(len, end-pos)` 裁剪                          | 1M 映射只用 16384                                                                              | ✅ 证实               |
| EROFS 的 `i_ino` 等于镜像里的 NID                                     | 打印的 ino 与 `dump.erofs` 的 NID 一致（42/44/46/40）                                          | ✅ 证实               |
| 目录读也走 iomap（数据在元数据块里 → INLINE）                         | ino=36（根目录）出现 `type=4`                                                                  | ✅ 附带证实           |
| **大 folio 场景下的 ifs 双位图与 `read_bytes_pending`「先加满后减」** | 本次所有 folio 均为 4096（== 块大小）⇒ `i_blocks_per_folio()==1` ⇒ ifs 未分配，`read_end` 0 次 | ⚠️ **未触发，未实测** |

关于最后一条需要说明的是：`erofs_fill_inode()` 确实无条件调用了 `mapping_set_large_folios()`  
（源码 `fs/erofs/inode.c` 中 `mapping_set_large_folios(inode->i_mapping);`），  
但**最终是否分配到高阶 folio 由 mm 的 readahead 分配器决定**，  
本次 8G 内存的 VM 里 186/186 都是 order-0 folio。  
这意味着：

* 之前那份「16K folio + `bytes_submitted` 累计到 12288 + `read_bytes_pending` 从 16384 递减到 0」属于**按源码规则推演的构造示例**，  
  本次没有实测到；  
* 真实测到的是**order-0 folio 下的按 folio 记账**：每个 folio 独立走 `iomap_read_end()`，  
  `bytes_submitted` 只可能是 0（空洞页）或 4096（数据页）。

---

## 6. 结论

1. **迭代推进规则完全按源码运行**：`iomap_iter_advance()` 每次只改 `pos`/`len`，  
   `iter_start_pos` 由 `iomap_iter_done()` 单点更新，    
   三段映射的推进量之和正好等于请求长度。  
2. **「空洞不产生 I/O」是硬事实**：186 段 range 中 8 段是空洞，   
   其 `bytes_submitted` 无一例外为 0，收尾由 `iomap_read_end()` 直接解锁 folio。  
3. **EROFS 只输出三种 type**（MAPPED / HOLE / INLINE），  
   `flags` 恒 0、`srcmap` 恒空，与「只读文件系统接入 iomap」的最小契约分析一致。  
4. **大 folio（ifs）分支是本次实验的盲区**。  
   它是否存在只取决于 mm 是否分配高阶 folio，与 EROFS/iomap 的代码无关；  
   要补测需要另外构造能稳定拿到高阶 folio 的负载。
