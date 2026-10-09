---
layout:     post
title:      EROFS addressing the image file
subtitle:   EROFS 寻址镜像文件
date:       2026-10-09
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 实测镜像 `img.erofs` 的 6 个文件：从超级块开始的磁盘寻址全过程

> **镜像**：`/home/linux/erofs/tmp-iloc2/img.erofs`
> **基线**：`bs = 4096`、`blkszbits = 12`、小端序、`mkfs.erofs` 1.9.4
> **内核**：`linux-stable` 7.3-rc5（`fs/erofs/`）
> **本文所有偏移/数值均为 `dump.erofs` + `od` 实测所得，不使用占位符。**

---

## 0. 超块基线（读到的第一批字节）

```
od -A d -t x1 -j 1024 -N 16 img.erofs
0001024  e2 e1 f5 e0  28 dc f1 6c  07 00 00 00  0c 00 63 00
```

| 字段 | 偏移 | 实测字节 | 解析 |
|---|---|---|---|
| `magic` | 1024 | `e2 e1 f5 e0` | `0xE0F5E1E2` ✓ |
| `checksum` | 1028 | `28 dc f1 6c` | crc32c |
| `feature_compat` | 1032 | `07 00 00 00` | 0x7 = `sb_csum\|mtime\|xattr_filter` |
| `blkszbits` | 1036 | `0c` | **12** → bs = 4096 |
| `sb_extslots` | 1037 | `00` | sb 大小 = 128 B |
| `rb.rootnid_2b` | 1038 | `63 00` | **99**（root 目录的 nid） |

`dump.erofs -s` 交叉验证：

```
Filesystem blocks:                            5
Filesystem inode metadata start block:        0      ← meta_blkaddr = 0
Filesystem shared xattr metadata start block: 0      ← xattr_blkaddr = 0
Filesystem root nid:                          99
Filesystem incompatible features:              （空：无压缩 / 无 chunk / 无 device table）
```

**由此确定的全局公式**

```
meta_blkaddr = 0
⇒ iloc(nid) = meta_blkaddr*4096 + nid*32 = nid * 32        (nid << 5)
⇒ 物理块号 = iloc / 4096
```

#### 镜像实际块分布

```
 block 0        : [resv 1KB][SB@1024 128B][元数据：inode + 共享 xattr(1152..)] 
 block 1 .. 3   : big.bin 的数据（3 块）
 block 4        : 元数据继续（s9.txt 的 inode 溢出到这里）
```

#### 本文要展开的 6 个文件

| # | 路径 | nid | iloc | 块 | 格式 | datalayout | size | xattr_isize |
|---|---|---|---|---|---|---|---|---|
| 1 | `/` | 99 | 3168 | 0 | compact | 2 FLAT_INLINE | 227 | 0 |
| 2 | `/big.bin` | 108 | 3456 | 0 | compact | 0 FLAT_PLAIN | 12288 | 0 |
| 3 | `/s1.txt` | 109 | 3488 | 0 | compact | 2 FLAT_INLINE | 3 | 16 |
| 4 | `/s5.txt` | 119 | 3808 | 0 | compact | 2 FLAT_INLINE | 3 | 16 |
| 5 | `/s10.txt` | 111 | 3552 | 0 | compact | 2 FLAT_INLINE | 4 | 16 |
| 6 | `/s9.txt` | **512** | **16384** | **4** | compact | 2 FLAT_INLINE | 3 | 16 |

---

## 1. 文件 ①：`/` —— 根目录（目录 + dirent 内联）

#### 结论

根目录的 **dirent 数据全部内联在元数据区**（`iloc + 32` 处，227 字节），
`i_u` 为 `EROFS_NULL_ADDR`（因为 `i_size=227 < bs` ⇒ `iblks=1` ⇒ `pos = 0`，没有数据区部分）。

#### 地址算术（逐步）

| 步 | 内核函数 | 计算 | 结果 |
|---|---|---|---|
| 1 | `erofs_read_superblock()` | 读 offset 1024 | `magic` OK，`meta_blkaddr = 0`, `rootnid = 99` |
| 2 | `erofs_iloc()` | `0*4096 + 99*32` | **iloc = 3168**（block 0） |
| 3 | `erofs_read_inode()` ← `erofs_read_metabuf()` | 读 3168 处 32 B | compact inode |
| 4 | 解析 `i_format` | `0x0004` → bit0=0（compact）；`(4>>1)&7 = 2` | **FLAT_INLINE** |
| 5 | `erofs_xattr_ibody_size(i_xattr_icount=0)` | 0 | `xattr_isize = 0` |
| 6 | dirent 起点 | `iloc + inode_isize(32) + xattr_isize(0)` | **3200** |
| 7 | `erofs_map_blocks()` | `m_la` → `pos=(1-1)*4096=0` ⇒ 走 inline 分支 | `m_pa = 3168+32+0+blkoff(m_la)`，`EROFS_MAP_META` |

#### inode 原始字节（@3168，32 B）

```
0003168  04 00 00 00 ed 41 02 00 e3 00 00 00 00 00 00 00
0003184  ff ff ff ff 01 00 00 00 00 00 00 00 00 00 00 00
```

| 字段 | 偏移 | 字节 | 值 | 含义 |
|---|---|---|---|---|
| `i_format` | 3168 | `04 00` | 0x0004 | compact + datalayout 2 |
| `i_xattr_icount` | 3170 | `00 00` | 0 | 无 xattr |
| `i_mode` | 3172 | `ed 41` | 0x41ed | **目录 0755** |
| `i_nb` | 3174 | `02 00` | 2 | nlink = 2 |
| `i_size` | 3176 | `e3 00 00 00` | **227** | dirent 数据字节数 |
| `i_mtime` | 3180 | `00 00 00 00` | 0 | |
| `i_u` | 3184 | `ff ff ff ff` | **EROFS_NULL_ADDR** | 无数据区部分 |
| `i_ino` | 3188 | `01 00 00 00` | 1 | |
| `i_uid`/`i_gid` | 3192/3194 | `00 00`/`00 00` | 0 | |

#### dirent 数组（@3200，13 项 × 12 B = 156 B）

```
0003200  63 00 00 00 00 00 00 00  9c 00 02 00   ← nid=99   nameoff=156 type=2  "."
0003212  63 00 00 00 00 00 00 00  9d 00 02 00   ← nid=99   nameoff=157 type=2  ".."
0003224  6c 00 00 00 00 00 00 00  9f 00 01 00   ← nid=108  nameoff=159 type=1  "big.bin"
0003236  6d 00 00 00 00 00 00 00  a6 00 01 00   ← nid=109  nameoff=166 type=1  "s1.txt"
0003248  6f 00 00 00 00 00 00 00  ac 00 01 00   ← nid=111  nameoff=172 type=1  "s10.txt"
0003260  71 00 00 00 00 00 00 00  b3 00 01 00   ← nid=113  nameoff=179 type=1  "s2.txt"
0003272  73 00 00 00 00 00 00 00  b9 00 01 00   ← nid=115  "s3.txt"
0003284  75 00 00 00 00 00 00 00  bf 00 01 00   ← nid=117  "s4.txt"
0003296  77 00 00 00 00 00 00 00  c5 00 01 00   ← nid=119  "s5.txt"
0003308  79 00 00 00 00 00 00 00  cb 00 01 00   ← nid=121  "s6.txt"
0003320  7b 00 00 00 00 00 00 00  d1 00 01 00   ← nid=123  "s7.txt"
0003332  7d 00 00 00 00 00 00 00  d7 00 01 00   ← nid=125  "s8.txt"
0003344  00 02 00 00 00 00 00 00  dd 00 01 00   ← nid=512  nameoff=221 "s9.txt" ★
0003356  2e 2e 2e 62 69 67 2e 62 69 6e 73 31 ... ← 名字区：".", "..", "big.bin", "s1.txt" ...
```

**自洽校验**：13 项 × 12 B = **156**，正好等于第 1 项的 `nameoff = 0x9c = 156` ✓
最后一项 `nameoff = 221` + 名字 6 B = **227 = `i_size`** ✓

#### 追问：root 数据末尾（3427）到下一个 inode（3456）之间的 29 字节是什么？

```
root inode   : 3168 .. 3199            （slot 99，32 B）
root dirent  : 3200 .. 3426            （227 B，内联）
下一个 inode : 3456                    （nid=108 → 108*32）
空隙         : 3427 .. 3455            共 29 字节
```

**实测内容：全 0**（`非零字节数: 0`）

```
od -A d -t x1z -j 3427 -N 29 img.erofs
0003427  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
0003443  00 00 00 00 00 00 00 00 00 00 00 00 00
```

**为什么是 29 字节、为什么下一个 inode 不紧贴着放？**

1. inode 的编址粒度是 **32 B 的 slot**：`iloc = meta_blkaddr*bs + nid*32`。
2. root 的数据从 3200（= slot 100）开始，**跨越了 slot 100..107**（共 8 个 slot = **256 B**，字节 3200..3455）。
   这 8 个 slot 被 root 的 dirent 数据"吃掉"，因此 **nid 100..107 不能再分配给别的 inode**。
3. root 实际只用了 227 B，剩余 `256 - 227 = 29 B` 未使用 → **零填充**。
4. 于是下一个可用 nid 只能是 **108** ⇒ `iloc = 108*32 = 3456`。

```
 slot 99        slot 100 ................ slot 107
 +--------+    +--------------------------+------------------------+
 | root   |    | root 的 dirent 数据 227B | 尾部 29B 未用(全 0)     |
 | inode  |    | (含 1B 的末名 NUL)       |                        |
 +--------+    +--------------------------+------------------------+
 3168..3199    3200..................3426  3427...............3455
                                            ↑
                                            3427 = 末名 "s9.txt" 的 NUL 结束符
                                            3428..3455 = 补齐到 slot 边界的 padding
                                      下一个 inode: slot 108 → 3456
```

> 细节：`3427` 这 1 个字节其实是最后一个文件名 `"s9.txt"` 的 **NUL 结束符**，
> 真正用于对齐的 padding 是 `3428..3455` 共 28 B。

#### 流程图

```
  SB@1024 ── meta_blkaddr=0, rootnid=99 ──┐
                                          │
  iloc = 0*4096 + 99*32 = 3168            │
        │                                 │
        ▼                                 │
  [block 0 @3168] erofs_inode_compact(32B)│
        │  i_format=0x0004 → datalayout 2 │
        │  i_size = 227, i_u = NULL_ADDR  │
        │  xattr_isize = 0                │
        ▼                                 │
  dirent @3200 (227B, 全在元数据区)        │
        │  13 × erofs_dirent(12B)         │
        │  nid=108 → /big.bin ────────────┼──▶ 见 §2
        │  nid=109 → /s1.txt  ────────────┼──▶ 见 §3
        │  nid=512 → /s9.txt  ────────────┴──▶ 见 §6（block 4）
```

---

## 2. 文件 ②：`/big.bin` —— 唯一的 FLAT_PLAIN（数据在数据区）

#### 结论

`i_u` = **startblk = 1**，数据占据 **block 1、2、3**（共 3 块 = 12288 B），
与 §1 中 dirent 指向的 nid=108 一致。

#### 地址算术

| 步 | 内核函数 | 计算 | 结果 |
|---|---|---|---|
| 1 | `erofs_iloc()` | `108*32` | **3456**（block 0） |
| 2 | 解析 `i_format` | `0x0000` → datalayout 0 | **FLAT_PLAIN**，`tailinline = 0` |
| 3 | `erofs_map_blocks()` | `pos = erofs_pos(sb, erofs_iblks(inode) - 0) = 3*4096 = 12288` | |
| 4 | 判据 `m_la < pos` | 恒成立（文件都在数据区） | 走 if 分支 |
| 5 | `m_pa` | `erofs_pos(sb, vi->startblk) + m_la` = `1*4096 + m_la` | **4096 + m_la** |
| 6 | `erofs_map_dev()` | 单设备，`m_bdev = sb->s_bdev` | 物理块 = `m_pa >> 12` |

#### inode 原始字节（@3456）

```
0003456  00 00 00 00 a4 81 01 00 00 30 00 00 00 00 00 00
0003472  01 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00
```

| 字段 | 字节 | 值 | 含义 |
|---|---|---|---|
| `i_format` | `00 00` | 0x0000 | compact + **datalayout 0** |
| `i_xattr_icount` | `00 00` | 0 | 无 xattr |
| `i_mode` | `a4 81` | 0x81a4 | 普通文件 0644 |
| `i_nb` | `01 00` | 1 | nlink=1 |
| `i_size` | `00 30 00 00` | **12288** | |
| `i_u` | `01 00 00 00` | **startblk = 1** | ★ |
| `i_ino` | `02 00 00 00` | 2 | |

#### 数据落点校验

```
block 1 (offset 4096)：65 82 ef 7b ae 9b f7 9c ...   ← 随机数据 ✓ 与 startblk=1 吻合
block 2, 3            ：同理（12288 / 4096 = 3 块）
```

#### 流程图

```
  iloc = 108*32 = 3456 ──▶ [inode] i_u.startblk = 1, i_size = 12288, datalayout 0
                                  │
        erofs_map_blocks(): pos = 3*4096 = 12288, m_la < pos 恒成立
                                  │
        m_pa = erofs_pos(sb, 1) + m_la = 4096 + m_la
                                  │
                                  ▼
        [block 1][block 2][block 3]     ← 数据区（4096 / 8192 / 12288）
```

---

## 3. 文件 ③：`/s1.txt` —— inline 数据 + 共享 xattr

#### 结论

文件体（`"d1\n"`，3 B）**内联在元数据**；xattr 只有 1 个 **共享** 属性，
其 id=288 指向 shared xattr 区（`xattr_blkaddr*bs + 4*288 = 1152`），值 `user.k = 'B'*2000`。

#### 地址算术

| 步 | 内核函数 | 计算 | 结果 |
|---|---|---|---|
| 1 | `erofs_iloc()` | `109*32` | **3488** |
| 2 | `i_format = 0x0004` | datalayout 2 | FLAT_INLINE |
| 3 | `i_xattr_icount = 2` | `12 + (2-1)*4` | **xattr_isize = 16** |
| 4 | xattr ibody 起点 | `3488 + 32` | **3520** |
| 5 | 读 `h_shared_xattrs[0]` | `3520+12 = 3532` → `20 01 00 00` | **id = 288** |
| 6 | shared xattr 偏移 | `xattr_blkaddr*4096 + 4*288` = `0 + 1152` | **1152** |
| 7 | idata 起点 | `3488 + 32 + 16` | **3536** |
| 8 | `erofs_map_blocks()` | `iblks=1` ⇒ `pos=0` ⇒ inline 分支 | `m_pa = 3488+32+16+blkoff(m_la) = 3536`，`EROFS_MAP_META` |

#### inode + xattr + idata 字节（@3488，64 B）

```
0003488  04 00 02 00 a4 81 01 00 03 00 00 00 00 00 00 00   ← inode
0003504  ff ff ff ff 03 00 00 00 00 00 00 00 00 00 00 00
0003520  ff bf ff ff 01 00 00 00 00 00 00 00 20 01 00 00   ← xattr ibody
0003536  64 31 0a 00 ...                                    ← idata = "d1\n"
```

| 区域 | 偏移 | 字段 | 字节 | 值 |
|---|---|---|---|---|
| inode | 3488 | `i_format` | `04 00` | 0x0004 → datalayout 2 |
| inode | 3490 | `i_xattr_icount` | `02 00` | **2** → xattr_isize 16 |
| inode | 3492 | `i_mode` | `a4 81` | 0644 |
| inode | 3496 | `i_size` | `03 00 00 00` | 3 |
| inode | 3504 | `i_u` | `ff ff ff ff` | NULL_ADDR（全内联） |
| xattr | 3520 | `h_name_filter` | `ff bf ff ff` | 名字过滤位图 |
| xattr | 3524 | `h_shared_count` | `01` | **1** 个共享属性 |
| xattr | 3532 | `h_shared_xattrs[0]` | `20 01 00 00` | **288** |
| idata | 3536 | — | `64 31 0a` | **`d1\n`** ✓ |

#### 共享 xattr 实体（@1152）

```
0001152  01 01 d0 07 6b 42 42 42 42 42 ...
```

| 字段 | 字节 | 值 |
|---|---|---|
| `e_name_len` | `01` | 1 |
| `e_name_index` | `01` | 1 = `USER` |
| `e_value_size` | `d0 07` | **2000** |
| `e_name` | `6b` | `"k"`（前缀 `user.` 由 index 提供） |
| value | `42`×2000 | `'B' * 2000` |

⇒ 完整属性名 **`user.k`**，值 2000 个 `B`；dedupe 后**只存一份**，
s1..s10 的 `h_shared_xattrs[0]` 全是 288，指向同一处 ✓

#### 流程图

```
  iloc = 109*32 = 3488
        │
        ├─▶ [inode 32B] i_format=4(inline) i_xattr_icount=2 i_size=3 i_u=NULL
        │
        ├─▶ [xattr ibody 16B @3520] h_shared_count=1, h_shared_xattrs[0]=288
        │         │
        │         └─▶ shared 区 @ (xattr_blkaddr*4096 + 4*288) = 1152
        │                └─▶ erofs_xattr_entry: user.k = 'B'*2000
        │
        └─▶ [idata @3536] "d1\n"      ← erofs_map_blocks() inline 分支，EROFS_MAP_META
```

---

## 4. 文件 ④：`/s5.txt`

#### 结论

与 s1 同构：inline + 共享 xattr(288) → 1152；`i_ino = 8`；内容 `"d5\n"`。

#### 字节（@3808）

```
0003808  04 00 02 00 a4 81 01 00 03 00 00 00 00 00 00 00   ← inode (i_ino=8)
0003824  ff ff ff ff 08 00 00 00 00 00 00 00 00 00 00 00
0003840  ff bf ff ff 01 00 00 00 00 00 00 00 20 01 00 00   ← xattr: shared id 288
0003856  64 35 0a 00 ...                                    ← idata = "d5\n"
```

地址算术：`iloc = 119*32 = 3808`；`idata = 3808+32+16 = 3856` → `64 35 0a` = `d5\n` ✓
共享 xattr 仍指向 `4*288 = 1152` ✓

---

## 5. 文件 ⑤：`/s10.txt`

#### 结论

唯一 size=4 的小文件（`"d10\n"`），其余与 s1 同构。

#### 字节（@3552）

```
0003552  04 00 02 00 a4 81 01 00 04 00 00 00 00 00 00 00   ← i_size = 4
0003568  ff ff ff ff 04 00 00 00 00 00 00 00 00 00 00 00   ← i_ino = 4
0003584  ff bf ff ff 01 00 00 00 00 00 00 00 20 01 00 00   ← shared id 288 → 1152
0003600  64 31 30 0a 00 ...                                 ← idata = "d10\n"
```

`iloc = 111*32 = 3552`；`idata = 3552+48 = 3600` → `64 31 30 0a` = `d10\n` ✓

> 注意：**nid 的顺序不等于文件名顺序**。`s10.txt` 的 nid=111 反而小于 `s2.txt` 的 113 ——
> nid 只是 slot 号，由 mkfs 分配顺序决定，查找必须走 dirent 的 `nameoff` 二分，不能按 nid 猜。

---

## 6. 文件 ⑥：`/s9.txt` —— nid 跳跃到 512（元数据被数据块分割）

#### 结论

这是本镜像最关键的一例：`s9.txt` 的 nid 是 **512**（不是相邻的 127），
因为 block 1–3 被 big.bin 的数据占用，元数据只能继续在 **block 4**，
而 block 4 的起始 slot = `4*128 = 512`。**寻址公式不变**（`iloc = nid*32`）。

#### 地址算术

| 步 | 计算 | 结果 |
|---|---|---|
| 1 | `iloc = meta_blkaddr*4096 + 512*32 = 0 + 16384` | **16384** |
| 2 | `16384 / 4096` | **block 4** |
| 3 | xattr_isize = 16（icount=2） | |
| 4 | xattr ibody | `16384+32 = 16416`，`h_shared_xattrs[0] = 288` → 1152 |
| 5 | idata | `16384+32+16 = 16432` |

#### 字节（@16384）

```
0016384  04 00 02 00 a4 81 01 00 03 00 00 00 00 00 00 00   ← inode (i_ino=12)
0016400  ff ff ff ff 0c 00 00 00 00 00 00 00 00 00 00 00
0016416  ff bf ff ff 01 00 00 00 00 00 00 00 20 01 00 00   ← shared id 288
0016432  64 39 0a 00 ...                                    ← idata = "d9\n"
```

#### 为什么 nid 不是 127 而是 512

```
 block 0      slot 0..127    元数据（inode + 1152 起的共享 xattr）
 block 1..3   slot 128..511  ★ 被 big.bin 的数据占用 ⇒ 这段 nid 被 mkfs 跳过
 block 4      slot 512..     元数据继续 ⇒ s9.txt 落在 slot 512
```

```
                ┌───────────── block 0 ─────────────┐
  slot 0..127   │ SB | inode(s) | xattr | idata ... │
                └───────────────────────────────────┘
                ┌─ block 1 ─┬─ block 2 ─┬─ block 3 ─┐
  slot 128..511 │ big.bin 0 │ big.bin 1 │ big.bin 2 │   ← 数据（nid 跳过）
                └───────────┴───────────┴───────────┘
                ┌───────────── block 4 ─────────────┐
  slot 512..    │ s9.txt inode | xattr | idata("d9")│
                └───────────────────────────────────┘
```

⇒ **不需要第二个元数据区指针**，一个 `meta_blkaddr` 加 `nid` 线性空间就够了。

#### 补充：本镜像里两种「nid 不连续」的区别（易混淆）

本文出现了两次 nid 跳号，但**机制完全不同**：

| | ① §1 root 之后 | ② §6 s9.txt |
|---|---|---|
| 现象 | nid **99** → 下一个 inode 是 **108**<br>（100..107 消失） | nid **125**(s8) → 下一个是 **512**<br>（126..511 消失） |
| 原因 | root 的**内联数据（dirent 227 B）占用了 slot 100..107** | **block 1..3 被 big.bin 的数据占用**，<br>slot 128..511 映射到的物理块是数据块 |
| 机制 | 元数据区**内部消耗**：inode 的内联数据<br>（dirent / idata / xattr）"吞掉"后续 slot | mkfs **主动跳过**映射到数据块的 nid 段，<br>把 inode 放到后面真正空闲的块 |
| 被跳过的字节里是什么 | 有内容（root 的 dirent 数据） | 是数据（big.bin 的内容），不能放 inode |

```
① root 的情形（元数据区内部消耗）
   slot 99        slot 100 .. 107
   [root inode]  [root 的 dirent 227B + 29B 全 0]
   3168..3199    3200 ...................... 3455
                 ↑ 这些 slot 被数据占用 ⇒ nid 100..107 不可分配
   下一个可用: slot 108 → 3456 ✓

② s9 的情形（跨过数据块）
   slot 0..127   slot 128..511     slot 512..
   [元数据]      [block1..3 数据]  [元数据继续]
   block 0       block 1,2,3       block 4
                 ↑ 这段 nid 映射到数据块 ⇒ 跳过
   s9 落在 slot 512 → 16384 = block 4 ✓
```

**共同点**：两种情况**寻址公式都不变**——始终只有一个 `meta_blkaddr`、一条
`iloc = meta_blkaddr*bs + nid*32`。nid 不连续只是 mkfs 分配的结果，
**不代表存在第二个元数据区、也不需要额外指针**。

> 由此得到一条实用规律：
> **inode 的内联数据（dirent / idata / xattr）会吞掉紧随其后的若干 slot**，
> 被吞掉的 nid 永久不可用。这解释了为什么「nid ≠ 文件序号」——
> 本镜像里 nid 从 99 直接跳到 108，中间 8 个号被 root 的目录数据吃掉了。

---

## 7. 特例（本镜像没有，用补充镜像 `sp.erofs` 实测）

补充镜像：`/home/linux/erofs/tmp-special/sp.erofs`（bs=4096，`meta_blkaddr=0`，root nid=36，13 块）

```
/           nid=36   layout2  size=103     nlink=3
/target.txt nid=107  layout2  size=6       nlink=2   ← 硬链接主体
/myhard     nid=107  layout2  size=6       nlink=2   ← ★ 与 target.txt 同 nid
/mylink     nid=109  layout2  size=10      nlink=1   ← 符号链接
/bigdir     nid=41   layout2  size=18433   nlink=2   ← 大目录
```

#### 7.1 fast symlink（短符号链接）

```
nid=109 → iloc = 109*32 = 3488
0003488  04 00 00 00 ff a1 01 00 0a 00 00 00 00 00 00 00
0003504  ff ff ff ff 04 00 00 00 ...
0003520  74 61 72 67 65 74 2e 74 78 74   ← idata = "target.txt"（10 字节）
```

- `i_mode = 0xa1ff` = **0120777（symlink）**
- `i_size = 10` = 目标字符串长度
- **没有数据块**：目标串直接内联在 `idata`（`iloc + inode_isize + xattr_isize = 3488+32+0 = 3520`）
- 内核：`erofs_fill_symlink()` 直接 `erofs_bread()` 读这段元数据，不走 `erofs_map_blocks()`
  ⇒ 寻址差异：**目标串 = idata，不产生 `m_pa` / 物理块**

```
  iloc=3488 ─▶ [inode] i_mode=0120777, i_size=10, i_u=NULL_ADDR
                   └─▶ idata @3520 = "target.txt"   ← 直接读元数据，无数据块
```

#### 7.2 硬链接

- `/target.txt` 与 `/myhard` 的 **nid 都是 107**，`nlink = 2`
- 差异不在 inode 寻址，而在**目录项**：两个不同的 `erofs_dirent` 指向**同一个 nid**
- 因此：两条路径 → 两个 dirent → 同一个 `iloc = 107*32` → 同一份 inode / 数据
- 内核：`erofs_iget()` 按 nid 取 inode，多 dirent 自然共享

```
  dirent("/target.txt") ─ nid=107 ─┐
                                    ├─▶ iloc = 107*32 ─▶ 同一个 inode（nlink=2）
  dirent("/myhard")     ─ nid=107 ─┘
```

#### 7.3 大目录（`i_u` = blkaddr）

```
nid=41 → iloc = 41*32 = 1312
0001312  04 00 00 00 ed 41 02 00 01 48 00 00 00 00 00 00
0001328  09 00 00 00 02 00 00 00 ...
```

| 字段 | 值 | 含义 |
|---|---|---|
| `i_mode` | 0x41ed | 目录 |
| `i_size` | `01 48 00 00` = **18433** | dirent 数据总量 |
| `i_u` | `09 00 00 00` = **9** | **startblk = 9** |

算术：

```
iblks      = round_up(18433, 4096) / 4096 = 20480/4096 = 5
tailinline = 1（datalayout 2）
pos        = (5 - 1) * 4096 = 16384
⇒ 数据区部分 [0, 16384)      → block 9,10,11,12（16384 B，位于数据区）
⇒ 尾部      [16384, 18433)   → 2049 B 内联进元数据 @ iloc+32 = 1344
```

```
  iloc = 41*32 = 1312
        │
        ├─▶ inode: i_size=18433, datalayout=2, i_u.startblk=9
        │
        ├─▶ 主体 dirent：block 9..12（数据区，16384 B）
        │        m_pa = erofs_pos(sb,9) + m_la = 36864 + m_la
        │
        └─▶ 尾部 dirent：2049 B 内联 @1344（EROFS_MAP_META）
```

⇒ 与小目录（§1，全内联）的差别：**大目录多了一次「数据块跳跃」**，
`i_u` 里存的是 dirent 数据块的起始块号，而不是文件内容。

---

## 8. 关键代码引用位置

| 环节 | 位置 |
|---|---|
| 读超块 / `meta_blkaddr`、`rootnid` | `fs/erofs/super.c: erofs_read_superblock()` |
| inode 定位 | `fs/erofs/internal.h: erofs_iloc()`（metabox 分支见同函数） |
| 解析 inode、定 `inode_isize`/`xattr_isize` | `fs/erofs/inode.c: erofs_fill_inode()` / `erofs_read_inode()` |
| xattr 区大小 | `fs/erofs/erofs_fs.h: erofs_xattr_ibody_size()` |
| xattr 初始化与校验 | `fs/erofs/xattr.c: erofs_init_inode_xattrs()` |
| flat / inline 映射 | `fs/erofs/data.c: erofs_map_blocks()` |
| chunk 映射 | `fs/erofs/data.c: erofs_map_chunks()` |
| 多设备（统一地址→具体设备） | `fs/erofs/data.c: erofs_map_dev()` / `erofs_fill_from_devinfo()` |
| 压缩映射 | `fs/erofs/zmap.c: z_erofs_map_blocks_iter()`、`z_erofs_load_full_lcluster()`、`z_erofs_load_compact_lcluster()` |
| 元数据读取（含 idata / dirent / symlink） | `fs/erofs/data.c: erofs_bread()`、`erofs_read_metabuf()` |
| 符号链接 | `fs/erofs/inode.c: erofs_fill_symlink()` |
| 目录查找（dirent 二分） | `fs/erofs/namei.c`、`fs/erofs/dir.c` |
| 结构体定义 | `fs/erofs/erofs_fs.h`（`erofs_super_block`、`erofs_inode_compact/extended`、`erofs_dirent`、`erofs_xattr_*`、`erofs_inode_chunk_index`、`z_erofs_*`） |

---

## 9. 附录：本文两个镜像的完整制作命令（可原样复现）

> 两条前置说明：
> 1. **工具路径**：用 `/home/linux/erofs/erofs-utils/` 下的 `mkfs.erofs` / `dump.erofs`（1.9.4）。
>    本机另有一份 `/opt/erofs-utils/bin/`（同版本），可互换。
> 2. **xattr 必须在支持扩展属性的文件系统上设置**：本文用 `/home/linux/erofs/`（ext4）。
>    若在 `/tmp`（多为 tmpfs）执行 `setfattr` 会失败 → 共享 xattr 不存在 →
>    布局与本文不同（inode 里就没有那 16 B 的 xattr 区，`s9.txt` 也不会跳到 512）。

#### 9.1 镜像 A：`img.erofs`（本文 §0–§6 的主镜像）

```bash
# ---------- ① 工作目录 ----------
W=/home/linux/erofs/tmp-iloc2
rm -rf $W; mkdir -p $W/src; cd $W

# ---------- ② 造测试数据 ----------
# big.bin：真随机 3 块（压不动）→ 占数据区 block 1..3，是"元数据被数据分割"的诱因
dd if=/dev/urandom of=src/big.bin bs=4096 count=3 2>/dev/null

# s1..s10.txt：小文件，各设一个 2000 B 的共享 xattr（值相同 ⇒ dedupe 成一份）
BIG=$(printf "B%.0s" $(seq 1 2000))
for i in $(seq 1 10); do
    echo "d$i" > src/s$i.txt
    setfattr -n user.k -v "$BIG" src/s$i.txt
done

# ---------- ③ 造镜像 ----------
M=/home/linux/erofs/erofs-utils/mkfs/mkfs.erofs
$M -b4096 img.erofs src

# ---------- ④ 复核（应与本文数据一致）----------
D=/home/linux/erofs/erofs-utils/dump/dump.erofs
$D -s img.erofs | grep -iE "blocks:|metadata start|root nid"
for p in / /big.bin /s1.txt /s9.txt /s10.txt; do $D --path=$p img.erofs | grep -E "NID|Layout|Size"; done
od -A d -t x1z -j 1024 -N 16 img.erofs          # 超块
od -A d -t x1z -j 3168 -N 64 img.erofs          # root inode + dirent
od -A d -t x1z -j 16384 -N 64 img.erofs         # s9 inode（block 4）
od -A d -t x1z -j 1152 -N 48 img.erofs          # 共享 xattr 实体
```

**预期产物**

| 项 | 值 |
|---|---|
| 镜像大小 / 块数 | 20480 B / **5 块** |
| `meta_blkaddr` / `xattr_blkaddr` | **0 / 0** |
| root nid | **99** |
| `big.bin` | nid 108，layout 0，`i_u` = startblk **1** |
| `s1..s8` | nid 109…125，layout 2（内联） |
| `s9.txt` | nid **512** → iloc 16384（block 4）★ |
| `s10.txt` | nid 111，size 4 |
| 共享 xattr | `h_shared_xattrs[0]` = 288 → 偏移 **1152**，`user.k` = `'B'*2000` |

#### 9.2 镜像 B：`sp.erofs`（§7 三个特例用）

```bash
# ---------- ① 工作目录 ----------
W=/home/linux/erofs/tmp-special
rm -rf $W; mkdir -p $W/src/bigdir; cd $W/src

# ---------- ② 造三类特例 ----------
echo "hello" > target.txt          # 6 字节（"hello\n"）
ln -s target.txt mylink           # 符号链接（短目标 → fast symlink）
ln target.txt myhard              # 硬链接（与 target.txt 同 inode / 同 nid）

# 大目录：500 个长名字文件 → dirent 数据 18433 B（> 1 块）→ 主体落到数据块
for i in $(seq 1 500); do echo x > bigdir/file_with_a_long_name_$i; done

# ---------- ③ 造镜像 ----------
cd $W
M=/home/linux/erofs/erofs-utils/mkfs/mkfs.erofs
$M -b4096 sp.erofs src

# ---------- ④ 复核 ----------
D=/home/linux/erofs/erofs-utils/dump/dump.erofs
$D -s sp.erofs | grep -iE "blocks:|metadata start|root nid"
for p in /target.txt /mylink /myhard /bigdir; do $D --path=$p sp.erofs | grep -E "NID|Layout|Size|Links"; done
od -A d -t x1z -j $((109*32)) -N 48 sp.erofs    # 符号链接 inode + idata("target.txt")
od -A d -t x1z -j $((41*32))  -N 48 sp.erofs    # 大目录 inode（i_u = startblk 9）
```

**预期产物**

| 项 | 值 |
|---|---|
| 镜像大小 / 块数 | 53248 B / **13 块** |
| root nid | **36** |
| `/target.txt` | nid **107**，nlink **2** |
| `/myhard` | nid **107**（同上 ⇒ 硬链接），nlink 2 |
| `/mylink` | nid 109，`i_mode = 0xa1ff`（0120777），size 10，idata = `"target.txt"` |
| `/bigdir` | nid 41，size **18433**，`i_u` = **9** ⇒ dirent 主体在 block 9..12，尾部 2049 B 内联 |

#### 9.3 复现自检清单

做完后按这 5 条核对，全部通过才说明拿到了与本文同一份镜像：

1. `blocks = 5`、`meta_blkaddr = 0`、`root nid = 99`（img.erofs）
2. `s9.txt` 的 **nid = 512** —— 若不是 512，说明 big.bin 没占住 block 1..3（多半 `dd` 随机数或 mkfs 参数有偏差）
3. 共享 xattr 的 id = **288**、偏移 **1152**、值是 2000 个 `B` —— 若 xattr 缺失则是 `setfattr` 失败，换到 ext4 目录重做
4. root 的 dirent 数组 **13 项 × 12 B = 156**，首个 `nameoff = 156`
5. `3427..3455` 这 **29 字节为全 0**（见 §1 的追问）

## 参考
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)  
[erofs-utils](https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git)  
[linux-stable (93f51579e7df)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  