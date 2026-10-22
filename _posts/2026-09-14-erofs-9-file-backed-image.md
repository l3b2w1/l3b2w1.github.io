---
layout:     post
title:      EROFS file-backed image
subtitle:   EROFS 文件后端
date:       2026-09-14
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
---

# 09 · 特性专题：文件后端（file-backed image / fileio）

> 对应配置：`CONFIG_EROFS_FS_BACKED_BY_FILE`  
> 主源码：`fileio.c`（158 行，是 EROFS 里最小的特性文件之一）  
> 代码基线：Linux 7.4-rc1 合并窗口之后（`/sdd/erofs/linux-stable`，HEAD `a804c5742bff`）  
>
> 本文回答六个问题：**为什么需要它**（缘由）→ **为什么会这样设计**（理念）→
> **它长什么样**（架构）→ **用到哪些结构体** → **关键函数在做什么** →
> **一次读的完整来龙去脉**。

## 本专题目标（读完你应该能做到什么）

1. 说清"文件后端"解决的是什么场景问题，以及**为什么不能简单用 loop 设备**
2. 解释 EROFS 怎么做到"用读文件的方式读一个块设备镜像"
3. 看懂 `erofs_fileio_rq` 里 **refcount 为什么初始为 2**
4. 解释 `bi_sector` 在这个文件里被**挪用**成了什么（这是全篇最巧妙的一处）
5. 说清 7.4 重构后 fileio 与 bdev 的差异**落在哪一层**（`iomap_read_ops`，而不再是 aops）
6. 独立读懂 `fileio.c` 的任意一行

> 若你对 `bio` 不熟，只需知道：**内核用 `bio` 描述一次块设备的 I/O**，  
> 里面带"从哪个扇区开始、读写多少、数据放哪些页"。

---

## 图解（先看这张图，再读正文）

![文件后端：意图与实现全景](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-14-erofs-26-fileio-intent-and-design.svg)

一张图分四段，自上而下读：

| 段 | 回答什么 | 一句话 |
|---|---|---|
| ① 意图（淡红/淡绿） | **为什么需要它** | 同一个镜像文件，bdev 路要绕 loop 设备（需特权），fileio 路直接 VFS 读（免特权） |
| ② 设计（淡蓝） | **在哪里分叉** | 前半段（iomap 框架 + `erofs_map_blocks` / `erofs_map_dev`）两条路共用，**只替换"提交 I/O"这一步** |
| ③ 实现（淡黄） | **分叉后怎么读** | iomap 框架遍历 folio 逐段回调 → MAPPED 段攒进 `erofs_fileio_rq` → `rq_submit`（扇区号还原成字节偏移）→ `vfs_iocb_iter_read` |
| ④ 三个必记的点 | **最容易踩的坑** | `bi_sector` 不是扇区号、`ref=2` 不是笔误、7.4 把 fileio 从"自带 aops"改成了"iomap 回调后端" |

**怎么读**：实线是执行流，虚线是"进入下一段"，点线只是把批注挂到对应节点上、不是流程。
节点里的 `>>9` / `<<9` 就是代码里的移位（`>>9` = 除以 512，`<<9` = 乘以 512）。

**关键提醒（图里红色那块）**：`fileio.c` 里的 `bio` 是**借用**的——  
`bi_sector` 被改成了"文件内偏移 ÷ 512"，所以这个 `bio` **绝不能交给块设备层**。  
理解这一点，整篇 `fileio.c` 就通了。
---

## 一、特性缘由：为什么需要文件后端

#### 1.1 正常情况：镜像挂在块设备上

EROFS 是只读文件系统，最常见的用法是：

```
镜像文件 (xxx.erofs)  ──loop 设备──►  当块设备挂载
```

`mount -o loop -t erofs xxx.erofs /mnt` 就是这样：内核把文件"伪装"成块设备，  
EROFS 照常发 `bio` 下去，loop 驱动再转成对文件的读写。

#### 1.2 问题：有些环境用不了 loop 设备

`loop` 设备是个**全局资源**，需要特权，而且在下面这些场景里不可用或很难用：

| 场景 | 为什么 loop 不行 |
|---|---|
| **容器内部** | 容器里通常没有创建 loop 设备的权限（需要 `CAP_SYS_ADMIN` 且主机放行） |
| **嵌套挂载** | 一个只读文件系统里再挂另一个只读文件系统 |
| **无特权环境** | 根本没有 `/dev/loop-control` 的访问权 |
| **大量镜像** | loop 设备数量有限（默认 8 个或需配置） |

而容器场景恰恰是 EROFS 的主战场之一（容器镜像、只读 rootfs）。

#### 1.3 需求：能不能直接读那个文件，不经过块设备？

镜像本来就是个**普通文件**。既然如此：

> 能不能让 EROFS 直接 `read()` 那个文件，而**不**把它变成块设备？

这就是 **file-backed image**（文件后端）：

```
镜像文件 (xxx.erofs)  ──直接 VFS 读──►  EROFS 解析
```

不再需要 loop 设备，也就不需要相应特权。

#### 1.4 术语：bdev vs fileio

代码里经常出现这两个词：

| 词 | 含义 |
|---|---|
| **bdev** | block device 后端——常规路径，镜像挂在块设备上 |
| **fileio** | 文件后端——本专题的主题，直接读文件 |

代码里判断当前是不是文件后端，用 `erofs_is_fileio_mode(sbi)`——本质是"`sbi->dif0.file` 非空"。

---

## 二、设计理念

#### 理念 1：不重写读路径，只替换"最后一公里"

EROFS 的读路径前面大部分（VFS → `erofs_map_blocks` 翻译出物理地址）  
**与后端无关**。真正需要区分的只有最后一步：**怎么把物理地址处的数据读进来**。

所以 fileio 的设计是：

- **保留**全部映射逻辑（`erofs_map_blocks` / `erofs_map_dev` 照用）
- **只替换**"提交 I/O"这一步

7.4 把这个理念**推进了一层**（见 §3.4）：不只是映射逻辑共用，  
连"遍历一个 folio、把里面的映射区间逐段切出来"这件事也交给通用的**iomap 框架**去做，fileio 只剩一个回调：  
「给我一段已映射的区间，我把它变成对文件的读」。  
这体现在代码组织上：`fileio.c` 从旧版的约 380 行缩到 **158 行**——被删掉的正是"自己遍历 folio"那部分。

#### 理念 2：把块设备 I/O"翻译"成文件读

常规路径最后一步是 `submit_bio(bio)`（交给块设备层）。
fileio 的做法是：

1. **照常构造 `bio`**（里面已经填好了要读哪些页、多少字节）
2. 但在提交时**不交给块设备层**，而是：
   - 从 `bio` 里取出那些页 → 组装成 `iov_iter`
   - 用 `vfs_iocb_iter_read()` 去读那个镜像**文件**

⇒ `bio` 在这里被当成**一个通用的"我要读这些页"的描述符**，
只是最终执行者从块设备换成了文件。

#### 理念 3：用 `bi_sector` 承载"文件内偏移"（最巧妙的一处）

块设备的 `bio` 用 **`bi_sector`（扇区号）** 表示位置，1 扇区 = 512 字节。
文件用 **字节偏移**。

fileio 的做法是**直接把文件偏移换算成扇区号塞进 `bi_sector`**：

```c
/* 元数据路径（erofs_read_meta_folio）*/
io.rq->bio.bi_iter.bi_sector = (io.dev.m_dif->fsoff + io.dev.m_pa) >> 9;

/* 数据路径：erofs_iomap_begin() 先把 iomap->addr 设成 fsoff + m_pa，
   iomap_sector() 再把它 >> 9 还原成"扇区号" */
```

然后在提交时再换回来：

```c
rq->iocb.ki_pos = rq->bio.bi_iter.bi_sector << SECTOR_SHIFT;   /* ×512 */
```

**为什么要绕这一圈？**

因为 `bio` 的位置字段就是 `bi_sector`，没有"字节偏移"这个位置。  
与其改 `bio` 结构，不如**复用现有字段、约定它表示文件内的扇区**。   
代价是：这个 `bio` **不能**真的交给块设备（否则会读到错误的扇区）——
所以 fileio 的 `bio` 只在 EROFS 内部流通。

> ⚠️ 这也是理解本特性的关键：`fileio.c` 里的 `bio` 是**借用**的，
> 它的语义被悄悄改了。

## 三、实现架构

#### 3.1 整体位置

```
                        VFS
                         │  read_folio / readahead
                         ▼
              erofs_aops（两种后端共用同一套 aops）
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
     iomap 框架（通用层）      z_erofs_aops（压缩，另见压缩专题）
              │
     iomap_iter → erofs_iomap_begin()     ← 前半段共用：
              │                              erofs_map_blocks / erofs_map_dev
              ▼
     iomap_read_folio_iter() 逐段处理
              │
     ┌────────┼─────────────────┐
     ▼        ▼                 ▼
  HOLE     INLINE(META)      MAPPED
  填零     直接 memcpy       提交底层 I/O  ◄── 只在这一步分叉
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
           iomap_bio_read_ops        erofs_fileio_iomap_read_ops
           （bdev：submit_bio）      （fileio：vfs_iocb_iter_read）★
```

要点：**非压缩数据的 aops 只有一套** `erofs_aops`（`data.c`），
bdev 与 fileio 的差异不再体现在 aops 上，而是下沉到
**`struct iomap_read_ops`** 这一个回调集合上。

#### 3.2 `aops` 的选择：`erofs_get_aops()` 现在只有两级

`aops`（`address_space_operations`）是"怎么读一页"的回调集合。
EROFS 一共定义了 **3 套**对外 aops：

| aops | 定义位置 | 用途 |
|---|---|---|
| `erofs_aops` | `data.c` | 非压缩——**bdev 与 fileio 共用** |
| `z_erofs_aops` | `zdata.c` | 压缩路径（其内部再按后端二选一提交） |
| `z_erofs_cache_aops` | `zdata.c` | managed cache（压缩数据缓存，不对外暴露） |

选择逻辑在 `erofs_get_aops()`（`internal.h`）：

```c
static inline const struct address_space_operations *
erofs_get_aops(struct inode *realinode)
{
	if (erofs_inode_is_data_compressed(EROFS_I(realinode)->datalayout)) {
		if (!IS_ENABLED(CONFIG_EROFS_FS_ZIP))
			return ERR_PTR(-EOPNOTSUPP);
		DO_ONCE_LITE_IF(realinode->i_blkbits != PAGE_SHIFT, ...);
		return &z_erofs_aops;                    /* ① 压缩 */
	}
	return &erofs_aops;                              /* ② 其余（含 fileio） */
}
```

> 📌 旧版（≤7.3）这里是**三级判断**，中间有一级
> `if (erofs_is_fileio_mode(...)) return &erofs_fileio_aops;`。
> 7.4 重构把 `erofs_fileio_aops` 删掉了，判断被挪到了 §3.3 的位置。

那 fileio 与 bdev 在哪里分叉？在 `erofs_read_folio()` / `erofs_readahead()`
（`data.c`）里，按挂载模式选 **`iomap_read_ops`**：

```c
struct iomap_read_folio_ctx read_ctx = {
	.ops = erofs_is_fileio_mode(sbi) ?
		&erofs_fileio_iomap_read_ops : &iomap_bio_read_ops,
	...
};
```

**压缩文件**即便跑在文件后端上，也先走 `z_erofs_aops`，
由压缩路径内部（`z_erofs_submit_queue()`，`zdata.c`）二选一：
fileio 走 `erofs_fileio_bio_alloc()` + `erofs_fileio_submit_bio()`，
bdev 走 `bio_alloc()` + `submit_bio()`。

> 📌 顺带澄清一个容易误记的点：**EROFS 没有 `erofs_fsdax_aops` 这样的东西**。
> FSDAX 不走 `aops`，而是走 **`vm_operations_struct`**（`erofs_dax_vm_ops`，
> 在 `data.c`）配合 `dax_iomap_rw()`。详见 FSDAX 专题。

#### 3.3 一次读的完整流程（非压缩数据）

```
① VFS 要读某页 → 调用 erofs_read_folio()（data.c，两种后端共用）

② 取 realinode
   iter_ctx.realinode = erofs_real_inode(folio_inode(folio), &need_iput)
   └ 若启用了 ishare，真实数据可能在另一个 inode 上（见 11 专题）

③ 按后端选 iomap_read_ops（fileio → erofs_fileio_iomap_read_ops）

④ iomap_read_folio()（fs/iomap/buffered-io.c）主循环：
   └ iomap_iter → erofs_iomap_begin()（data.c）
        ├ erofs_map_blocks() → m_pa / m_llen / m_deviceid / m_flags
        ├ erofs_map_dev()    → m_dif（含镜像文件 file）+ fsoff
        └ 按 m_flags 设置 iomap：
             空洞           → type = IOMAP_HOLE
             尾部内联(META) → type = IOMAP_INLINE，inline_data 指向 metabuf
             正常映射       → type = IOMAP_MAPPED，
                              addr = fsoff + m_pa（文件内绝对偏移！）
                              private = m_dif      （fileio 要从这里拿文件）

⑤ iomap_read_folio_iter()（buffered-io.c）按 type 分派：
        ├ INLINE → iomap_read_inline_data()  直接 memcpy，不发 I/O
        ├ HOLE   → folio_zero_range() 填零
        └ MAPPED → ctx->ops->read_folio_range()
                   = erofs_fileio_iomap_read_folio_range()（fileio.c）
                        ├ 与上一个 rq 物理连续（bio_end_sector == sector）
                        │  → bio_add_folio() 追加进同一个 rq
                        └ 否则 → 先提交旧 rq，再 alloc 新 rq
⑥ 每个映射区间结束后 iomap 框架调 submit_read()
   = erofs_fileio_iomap_submit_read() → erofs_fileio_rq_submit()
        ├ ki_pos = bi_sector << 9        ← 扇区换回字节偏移
        ├ iov_iter_bvec(...)             ← bio 的页转成 iov_iter
        └ vfs_iocb_iter_read()           ← 真正去读文件

⑦ 完成回调 erofs_fileio_ki_complete()
   ├ 数据 bio（bi_end_io == NULL）：逐 folio 调 iomap_finish_folio_read()
   │   （账本在 iomap 层的 ifs->read_bytes_pending，到零即 folio_end_read）
   └ refcount_dec_and_test() → 释放 rq
```

与旧版对比的关键变化：**第 ⑤ 步的"逐段切分"由 iomap 框架完成**，
fileio 不再自己写循环；空洞与内联数据这两种"不用发 I/O"的情况
也由框架统一处理。

#### 3.4 上游演进：7.4 的 iomap 化（重要）

fileio 在上游经历了两次大改，本专题正文已经是**最终结果**：

| | 7.2 及更早 | 7.3 | 7.4（本文基线） |
|---|---|---|---|
| 数据路径 | `erofs_fileio_aops` + 自带 `scan_folio` 循环 | 同左 | **共用 `erofs_aops`，差异下沉到 `iomap_read_ops`** |
| 元数据 mapping | 复用**镜像文件**的页缓存 | managed cache | managed cache（不变） |
| 元数据读取回调 | `read_mapping_folio(..., buf->file)` | `read_cache_folio(..., erofs_read_meta_folio)` | 同左（不变） |
| `struct erofs_buf` | 有 `file` 字段 | `file` 移除，新增 `bool mc` | 不变 |
| 挂载选项 | — | 新增 `source` | 新增 `superblock_share`（见 §3.6） |

7.4 这次重构（提交 `1137aa577a35`）的动机：旧版 fileio 自己实现
"扫描 folio、逐段切分、空洞填零、内联 memcpy"，这些其实是**每个
iomap 文件系统都要做的事**；iomap 框架早已把它们做成了通用层
（`iomap_read_folio()` / `iomap_read_folio_iter()`），只要文件系统
提供两个回调（`iomap_begin` 描述映射、`read_folio_range` 提交 I/O）
就能直接复用。fileio 迁过来之后：

- `erofs_fileio_aops`、`erofs_fileio_read_folio`、`erofs_fileio_readahead`、
  `erofs_fileio_scan_folio` **全部删除**
- 空洞填零、inline memcpy、folio 完成计数（`ifs->read_bytes_pending`）
  都由 iomap 通用层负责——**这也顺带修复了旧版 len==0 时
  folio 完成计数不平衡导致 soft lockup 的一类问题**（框架里有
  无条件的 `iomap_read_end()` 兜底）
- fileio 只剩「MAPPED 区间 → 攒进 rq → `vfs_iocb_iter_read`」
  这最后一公里

#### 3.5 元数据读取：managed cache + fileio bio

元数据（超级块、inode、xattr、chunk 索引……）的读取走另一条路，
**两种后端共用同一个入口** `erofs_bread()`（`data.c`），差异藏在
`struct erofs_buf` 里：

```c
/* erofs_init_metabuf()（data.c）*/
buf->mc = false;
if (in_metabox) { buf->mapping = sbi->metabox_inode->i_mapping; return 0; }
if (erofs_is_fileio_mode(sbi)) {
	buf->mapping = sbi->managed_cache->i_mapping;   /* ← fileio */
	buf->mc = true;
} else {
	buf->off = sbi->dif0.fsoff;
	buf->mapping = sb->s_bdev->bd_mapping;          /* ← bdev */
}
```

`erofs_bread()` 按 `buf->mc` 决定是否显式传读取回调：

```c
folio = read_cache_folio(buf->mapping, index,
		buf->mc ? erofs_read_meta_folio : NULL, NULL);
```

fileio 模式下回调 `erofs_read_meta_folio()`（`fileio.c`）登场：
它把"读 managed cache 的某一页"翻译成一次 fileio 请求——

```c
err = erofs_map_dev(inode->i_sb, &io.dev);        /* folio_pos 即虚拟地址 */
io.rq = erofs_fileio_rq_alloc(inode->i_sb, io.dev.m_dif->file);
io.rq->bio.bi_end_io = erofs_fileio_meta_endio;   /* ★ 元数据专用完成回调 */
io.rq->bio.bi_iter.bi_sector = (io.dev.m_dif->fsoff + io.dev.m_pa) >> 9;
bio_add_folio_nofail(&io.rq->bio, folio, folio_size(folio), 0);
erofs_fileio_rq_submit(io.rq);
```

⇒ **元数据读取也复用了理念 3 的 `bi_sector` 约定**，与数据读取
走同一套 fileio 机制；区别在于完成回调（见 §5.3 的 `bi_end_io` 分工）。

注意这里 `erofs_map_dev()` 的输入 `m_pa` 直接是 `folio_pos(folio)`
（页号 × 页大小）——fileio 下 managed cache 的页索引本身就是
"镜像虚拟地址 ÷ 页大小"，所以映射一步到位。

#### 3.6 挂载选项 `superblock_share`（7.4 新增）

7.4 还给文件后端加了一个配套选项：**同一镜像文件多次挂载时，
复用同一个 `super_block`**（提交 `cd4108319bb3`）。

- 打开方式：`-o superblock_share`，**仅文件后端可用**
- 复用判据（`erofs_sb_share_test_super()`，`super.c`）：
  两边 `dif0.file` 指向**同一个 inode**（注意比的是 inode 不是 file，
  所以同一文件被 open 两次也能命中）、`fsoffset` 相同、
  且挂载选项结构体 `opt` 逐字节相同
- 限制：与 `inode_share` 互斥、不支持 extra devices、
  挂载后禁止 remount（直接 `-EBUSY`）、`/proc/mounts` 里**看不到**该选项
  （`erofs_show_options()` 不导出）

容器场景的意义：N 个容器挂同一个镜像，只解析一次超级块、
只建一份内部缓存 inode。

---

## 四、关键结构体

#### 4.1 `struct erofs_fileio_rq`（`fileio.c`）

**一次文件读请求的载体**。这是本特性的核心结构体，7.4 重构后原样保留。

```c
struct erofs_fileio_rq {
	struct bio_vec bvecs[16];   /* 最多 16 个 bio_vec（页片段）*/
	struct bio bio;             /* 内嵌的 bio */
	struct kiocb iocb;          /* 内核 I/O 控制块（用于读文件）*/
	struct super_block *sb;
	refcount_t ref;             /* ★ 引用计数，初始为 2 */
};
```

| 字段 | 说明 |
|---|---|
| `bvecs[16]` | `bio` 用的 bvec 数组。**限长 16** —— 一次最多聚合 16 个页片段 |
| `bio` | 内嵌的 `bio`。**注意它的 `bi_sector` 被当作文件偏移用**（见理念 3） |
| `iocb` | 用于 `vfs_iocb_iter_read()`。`ki_filp` 指向镜像文件 |
| `ref` | **初始为 2**：一个引用给"提交者"，一个给"完成回调" |

###### 为什么 `ref` 初始为 2 ？

这是理解并发的关键。

一次异步读涉及**两个可能先后结束的持有者**：

1. **提交方**（`erofs_fileio_rq_submit`）—— 提交完后就不需要 `rq` 了
2. **完成回调**（`erofs_fileio_ki_complete`）—— IO 完成时才用得到

如果引用计数是 1，那么先结束的一方释放后，另一方就会**用已释放的内存**。

所以初始化为 2，两方各 `refcount_dec_and_test()` 一次，
**谁最后结束谁负责释放**（`kfree`）。

```c
refcount_set(&rq->ref, 2);                    /* 分配时 */
...
/* 提交方末尾 */
if (refcount_dec_and_test(&rq->ref))
        kfree(rq);
/* 完成回调末尾 */
if (refcount_dec_and_test(&rq->ref))
        kfree(rq);
```

#### 4.2 `struct erofs_fileio`（`fileio.c`）

**元数据读的一次性上下文**（栈上变量，不分配）：

```c
struct erofs_fileio {
	struct erofs_map_blocks map;   /* 当前映射结果 */
	struct erofs_map_dev dev;      /* 当前解析出的设备/文件 */
	struct erofs_fileio_rq *rq;    /* 正在构造的请求 */
};
```

> 📌 旧版它是"folio 扫描的跨 folio 复用上下文"（配合已删除的
> `scan_folio` 做 I/O 聚合）。7.4 后扫描职责移交 iomap 框架，
> 它只剩一个使用点：`erofs_read_meta_folio()` 里把 map/dev/rq
> 打包传递。数据路径的聚合改由 `iomap_read_folio_ctx.read_ctx`
> 持有"正在攒的 rq"来实现。

#### 4.3 iomap 侧的三个结构体（7.4 新增的关键依赖）

| 结构体 | 位置 | 在 fileio 里的作用 |
|---|---|---|
| `struct iomap_read_ops` | `include/linux/iomap.h` | **后端抽象**：`read_folio_range`（提交一段）+ `submit_read`（提交攒下的全部）。fileio 与 bdev 各实现一份 |
| `struct iomap_read_folio_ctx` | 同上 | 一次读的状态：`ops`、`cur_folio`、`rac`（预读时）、`read_ctx`（fileio 用它存"正在攒的 rq"） |
| `struct erofs_iomap_iter_ctx` | `internal.h` | EROFS 侧上下文：`realinode`（ishare 换 inode）、`page`/`base`（把 inline 元数据的 metabuf 钉到迭代结束） |

`erofs_iomap_begin()`（`data.c`）与这三个结构体的配合是 7.4 重构的
枢纽：它把 `erofs_map_blocks` + `erofs_map_dev` 的结果翻译成
iomap 语言（type / addr / private），**fileio 要的镜像文件就是
通过 `iomap->private = m_dif` 传进回调的**。

#### 4.4 相关的通用结构体（详见 08 专题）

| 结构体 | 在这里的作用 |
|---|---|
| `erofs_map_blocks` | `m_pa`（物理地址）、`m_la`、`m_llen`、`m_deviceid`、`m_flags` |
| `erofs_map_dev` | 解析出具体文件：`m_dif->file` 与 `m_pa` |
| `erofs_device_info` | `file` 字段——**镜像文件就在这里**；`fsoff` 是本设备内偏移 |

---

## 五、主要函数

#### 5.1 对外接口（被其他文件调用）

| 函数 | 作用 |
|---|---|
| `erofs_fileio_bio_alloc()` | 分配一个"伪装成 bio"的 `erofs_fileio_rq`，返回它的 `bio` |
| `erofs_fileio_submit_bio()` | 提交：不交给块设备，而是转成文件读 |
| `erofs_read_meta_folio()` | 元数据读取回调（见 §3.5） |
| `erofs_fileio_iomap_read_ops` | 非压缩数据路径的 `iomap_read_ops` 实例 |

前两个函数是**压缩路径与 fileio 的唯一接口**——命名刻意与块设备接口
一致（`bio_alloc` / `submit_bio`），这样 `zdata.c` 的提交队列不用改。

#### 5.2 请求生命周期三函数

#### `erofs_fileio_rq_alloc()` —— 分配与初始化

```c
struct erofs_fileio_rq *rq = kzalloc_obj(...);
bio_init(&rq->bio, NULL, rq->bvecs, ARRAY_SIZE(rq->bvecs), REQ_OP_READ);
rq->iocb.ki_filp = file;            /* ← 要读的文件 */
rq->sb = sb;
refcount_set(&rq->ref, 2);
```

要点：
- `bio_init()` 时 **不设 `bi_end_io`**（为 NULL）—— 这个细节在 5.3 会用到
- `ki_filp` 直接指向镜像文件

#### `erofs_fileio_rq_submit()` —— 提交（关键）

```c
rq->iocb.ki_pos = rq->bio.bi_iter.bi_sector << SECTOR_SHIFT;   /* 扇区→字节 */
rq->iocb.ki_complete = erofs_fileio_ki_complete;

if (test_opt(&EROFS_SB(rq->sb)->opt, DIRECT_IO) &&
    rq->iocb.ki_filp->f_mode & FMODE_CAN_ODIRECT)
	rq->iocb.ki_flags = IOCB_DIRECT;                        /* 可选：绕过页缓存 */

iov_iter_bvec(&iter, ITER_DEST, rq->bvecs, rq->bio.bi_vcnt,
	      rq->bio.bi_iter.bi_size);
scoped_with_creds(rq->iocb.ki_filp->f_cred)
	ret = vfs_iocb_iter_read(rq->iocb.ki_filp, &rq->iocb, &iter);

if (ret != -EIOCBQUEUED)
	erofs_fileio_ki_complete(&rq->iocb, ret);
if (refcount_dec_and_test(&rq->ref))
	kfree(rq);
```

要点：

1. **`ki_pos` 从 `bi_sector` 换回字节偏移**（理念 3 的逆运算）
2. **DIRECT_IO 是可选的**：若挂载时指定且文件支持 `O_DIRECT`，
   就绕过页缓存直接读——避免"镜像文件的页缓存"与"EROFS 的页缓存"**双重缓存**
3. **`scoped_with_creds()`**：用文件自己的凭据去读（多用户环境下权限正确）
4. **同步/异步统一处理**：
   - 返回 `-EIOCBQUEUED` → 异步，稍后由回调处理
   - 其他 → 同步完成，这里直接调完成回调

#### `erofs_fileio_ki_complete()` —— 完成回调

```c
if (ret >= 0 && ret != rq->bio.bi_iter.bi_size)
	ret = -EIO;                        /* 读到的长度不对 → 报错 */

if (!rq->bio.bi_end_io) {                  /* ★ 没有 bi_end_io = iomap 数据路径 */
	bio_for_each_folio_all(fi, &rq->bio) {
		DBG_BUGON(folio_test_uptodate(fi.folio));
		iomap_finish_folio_read(fi.folio, fi.offset, fi.length,
					ret < 0 ? ret : 0);
	}
} else if (ret < 0 && !rq->bio.bi_status) {
	rq->bio.bi_status = errno_to_blk_status(ret);
}
bio_endio(&rq->bio);
bio_uninit(&rq->bio);
if (refcount_dec_and_test(&rq->ref))
	kfree(rq);
```

**`if (!rq->bio.bi_end_io)` 这一句很关键**，它区分两种来源：

- `bi_end_io == NULL`：**iomap 数据路径的 bio**。fileio 不直接结束 folio，
  而是逐段调 `iomap_finish_folio_read()`——由 iomap 层的账本
  （`ifs->read_bytes_pending`）决定何时真正 `folio_end_read()`。
  一个 folio 可能被拆到多个 rq 里，必须等所有段都完成。
- `bi_end_io != NULL`：**元数据路径的 bio**（`erofs_read_meta_folio`
  设了 `erofs_fileio_meta_endio`）。只更新 `bi_status`，
  随后的 `bio_endio()` 会调到 `erofs_fileio_meta_endio()`，
  由它对每个 folio 直接 `folio_end_read()`——元数据一次读一整页，
  不需要分段账本。

> 📌 旧版这里调的是 `erofs_onlinefolio_end()`（EROFS 自己的完成计数），
> 7.4 换成了 iomap 的 `iomap_finish_folio_read()`——完成账本随遍历
> 职责一起移交给了框架。

#### 5.3 iomap 回调两函数（7.4 新增，数据路径的主体）

#### `erofs_fileio_iomap_read_folio_range()` —— 攒一段

iomap 框架每切出一段 MAPPED 区间就调它一次：

```c
sector_t sector = iomap_sector(&iter->iomap, iter->pos);   /* 含 fsoff */

if (!rq || bio_end_sector(&rq->bio) != sector ||
    !bio_add_folio(&rq->bio, folio, plen, offset_in_folio(folio, iter->pos))) {
	struct erofs_device_info *dif = iter->iomap.private;   /* ← 镜像文件在这 */

	if (ctx->read_ctx)
		erofs_fileio_iomap_submit_read(iter, ctx);       /* 先提交旧的 */
	rq = erofs_fileio_rq_alloc(sb, dif->file);
	rq->bio.bi_iter.bi_sector = sector;
	bio_add_folio_nofail(&rq->bio, folio, plen, ...);
	ctx->read_ctx = rq;                                    /* 攒着，继续 */
}
```

⇒ **物理连续就合并，不连续就切开**——旧版 scan_folio 里的
`io_retry` 逻辑现在浓缩成 `bio_end_sector(&rq->bio) != sector`
这一个判断（`bi_end_sector` 是"下一个期望扇区"，相等即连续）。

注意 `iter->iomap.private` 就是 `erofs_iomap_begin()` 存的 `m_dif`，
fileio 从这里拿到要读的镜像文件。

#### `erofs_fileio_iomap_submit_read()` —— 提交攒下的全部

```c
static void erofs_fileio_iomap_submit_read(const struct iomap_iter *iter,
		struct iomap_read_folio_ctx *ctx)
{
	erofs_fileio_rq_submit((struct erofs_fileio_rq *)ctx->read_ctx);
	ctx->read_ctx = NULL;
}
```

iomap 框架在**每个映射区间处理完之后**调它（也可能在 folio 结束、
整个 read 结束时被框架兜底调用），把 `read_ctx` 里攒着的 rq 发出去。

⇒ `read_ctx` 的生命周期就是"一个可以连续聚合的窗口"：
`read_folio_range` 往里攒，`submit_read` 把它清空。

---

## 六、来龙去脉：完整串一遍

假设容器里要读 EROFS 镜像中的某个文件第一页（非压缩、非内联）：

```
① 容器没有 loop 权限，但能打开镜像文件
        │
② 挂载：-o source=xxx.erofs（或 fd），sbi->dif0.file 指向镜像文件
        │  erofs_is_fileio_mode() 为真
        │
③ 进程 read() → VFS 发现页不在缓存 → erofs_aops.read_folio
        │  = erofs_read_folio()（data.c，与 bdev 共用）
        ├ erofs_real_inode() 取真实 inode（ishare 时可能换）
        └ read_ctx.ops = &erofs_fileio_iomap_read_ops（fileio 模式）
        │
④ iomap_read_folio() → erofs_iomap_begin()
        ├ erofs_map_blocks() → m_pa（镜像内偏移）、m_deviceid
        ├ erofs_map_dev()    → m_dif->file（镜像文件）+ fsoff
        └ iomap->type=MAPPED, addr=fsoff+m_pa, private=m_dif
        │
⑤ iomap_read_folio_iter() → read_folio_range()
        = erofs_fileio_iomap_read_folio_range()
        └ bio_add_folio() 把目标页加进 rq->bio（bi_sector 已是文件内扇区）
        │
⑥ iomap 框架调 submit_read() → erofs_fileio_rq_submit()
        ├ ki_pos = bi_sector << 9     ← 扇区号还原成文件偏移
        ├ iov_iter_bvec()             ← bio 的页 → iov_iter
        └ vfs_iocb_iter_read()        ← 读！不再经过块设备
        │
⑦ 文件读完成 → ki_complete 回调
        ├ 逐 folio 段 iomap_finish_folio_read()
        │   （iomap 账本归零才真正 folio_end_read）
        └ refcount 减到 0 → kfree(rq)
        │
⑧ 页变成 uptodate → read() 返回数据
```

**整条链上没有出现块设备层**，这就是文件后端的本质。

若是**元数据**（比如挂载时读超级块、读 inode 表），链路在第 ③ 步就不同：

```
③' erofs_bread()（mc=true）→ read_cache_folio(managed_cache, index,
                                              erofs_read_meta_folio)
④' erofs_read_meta_folio()：folio_pos 当虚拟地址 → erofs_map_dev()
     → 整页 bio_add_folio_nofail() → erofs_fileio_rq_submit()
⑦' 完成 → bio_endio → erofs_fileio_meta_endio → folio_end_read 整页收尾
```

---

## 七、动手验证

#### 验证 1：确认配置是否启用

```bash
grep EROFS_FS_BACKED_BY_FILE /sdd/erofs/linux-stable/.config
# CONFIG_EROFS_FS_BACKED_BY_FILE=y
```

#### 验证 2：看 fileio 的后端实例在哪被选中

```bash
cd /sdd/erofs/linux-stable/fs/erofs
grep -n "erofs_fileio_iomap_read_ops" *.c *.h
```

应该能看到它在 `data.c` 的 `erofs_read_folio()` / `erofs_readahead()`
里按 `erofs_is_fileio_mode()` 被选中——**对照一下选中条件**，
就能确认"什么时候走文件后端"。
（旧版这里查的是 `erofs_fileio_aops`，该符号在 7.4 已删除。）

#### 验证 3：在 QEMU 里实测文件后端挂载

这是最有说服力的验证（需要镜像文件而非块设备）：

```bash
# VM 内（9p 已把 /sdd/erofs 挂到 /host）
mount -t erofs -o source=/host/plain.erofs /mnt/f
cat /mnt/f/big.bin | head -c 100
dmesg | grep -i erofs
```

> 挂载选项的确切写法以 `super.c` 里的 **`erofs_fs_parameters[]`**
> （`fs_parameter_spec` 数组）为准：当前有 `source`（文件或路径）
> 与 `superblock_share` 等。
>
> ⚠️ 源码里**没有** `struct erofs_fs_context` 这样一个结构体；
> 承载选项的是 `erofs_fs_parameters[]` 与 `erofs_context_ops`
> 这一套 `fs_context` 机制。

#### 验证 4：观察是否真的绕过了块设备

若挂载成功且能读数据，而**没有**创建任何 loop 设备，即证明走的是文件后端：

```bash
losetup -a      # 应看不到与本次挂载相关的 loop 设备
```

---

## 八、常见误解（重要）

#### 误解 1：文件后端就是把镜像当普通文件读，所以性能一定差

不对。它**仍然可以聚合 I/O**（一次 `rq` 最多 16 个 bvec），
也**可以用 `O_DIRECT`** 绕过双重缓存。
真正的差异在于少了块设备层的一层转换——某些场景反而更快。

#### 误解 2：`bvecs[16]` 意味着一次只能读 16 个页

不完全对。16 是**一次 `rq` 的 bvec 上限**；
`read_folio_range` 里 `bio_add_folio()` 失败（bio 满了）或位置不连续时
会**先提交旧的、再开新的**，所以总量不受 16 限制。

#### 误解 3：`bi_sector` 还是扇区号

在 `fileio.c` 里**不是**。它被用作"文件内偏移 ÷ 512"，
提交时再乘回来。**这个 bio 绝不能交给块设备层**。

#### 误解 4：`refcount` 初始为 2 是笔误

不是。它对应"提交方"和"完成回调"两个持有者，
谁最后结束谁释放。改成 1 会导致 use-after-free。

#### 误解 5：文件后端与 ishare 互斥

不互斥。`erofs_read_folio()` / `z_erofs_read_folio()` 里都调用了
`erofs_real_inode()`，说明**两者可以叠加**——文件后端提供"从哪读"，
ishare 决定"用谁的页缓存"。

#### 误解 6：fileio 有自己的一套 `aops`

7.4 之后**没有了**。`erofs_fileio_aops` 已删除，非压缩数据的
bdev 与 fileio 共用 `erofs_aops`；差异只在 `iomap_read_ops`
这个更小的回调集合上。看到旧文档/旧补丁里引用
`erofs_fileio_aops` / `erofs_fileio_scan_folio`，注意那描述的是 ≤7.3。

---

## 九、与其他特性的关系

| 特性 | 关系 |
|---|---|
| **iomap 框架**（非 EROFS 特性） | 7.4 起 fileio 的数据路径建立在它之上：遍历/填零/inline/账本全由框架负责 |
| **ishare / page cache sharing**（11 专题） | 可叠加。读路径入口调用 `erofs_real_inode()` |
| **FSDAX**（10 专题） | 另一种"绕开块设备/页缓存"的方案，思路不同但目标相近；fileio 目前**不支持** DAX（`erofs_fc_get_tree()` 要求 backing 是普通文件且带 `read_folio`） |
| **多设备** | fileio 也走 `erofs_map_dev()`，所以多设备逻辑**照常工作**（每个设备可以是各自的镜像文件） |
| **压缩路径** | 压缩数据的读取也走同一套后端抽象：`z_erofs_submit_queue()` 里按模式**二选一** —— fileio 走 `erofs_fileio_bio_alloc()` + `erofs_fileio_submit_bio()`，块设备走 `bio_alloc()` + `submit_bio()` |
| **superblock_share**（§3.6） | fileio 专用：同镜像多次挂载复用 sb |
| **DIRECT_IO 选项** | fileio 专用优化，避免双重页缓存 |

---

## 自测检查点

1. 文件后端解决什么问题？举一个 loop 设备不可用的场景。
2. `bdev` 与 `fileio` 分别指什么？代码里怎么判断当前是 fileio？
3. 为什么 fileio 不重写整个读路径？7.4 之后它替换的是哪一步？
4. `bi_sector` 在 fileio 里被当成什么用？为什么要这样绕？
5. `erofs_fileio_rq.ref` 为什么初始为 2？改成 1 会怎样？
6. `bvecs[16]` 满了之后怎么办？
7. `erofs_fileio_ki_complete()` 里 `!rq->bio.bi_end_io` 这个判断在区分什么？
8. iomap 框架替 fileio 处理了哪三种区间类型？空洞怎么表示？
9. `DIRECT_IO` 选项在 fileio 里解决什么问题？
10. 为什么说文件后端与 ishare 可以叠加？
11. `superblock_share` 的复用判据是什么？为什么它只对 fileio 有意义？

---

## 自测答案

<details>
<summary>点击展开</summary>

1. 解决"镜像是文件但无法/不便用 loop 设备"的问题。典型场景：**容器内部**没有创建
   loop 设备的权限（需要 `CAP_SYS_ADMIN`）。此外还有嵌套挂载、无特权环境、loop 数量受限。

2. `bdev` = block device 后端（常规，镜像挂在块设备上）；
   `fileio` = 文件后端（直接 VFS 读镜像文件）。
   判断：`erofs_is_fileio_mode(sbi)`，即 `sbi->dif0.file` 非空。

3. 因为前面大半（VFS → `erofs_map_blocks` 翻译物理地址）**与后端无关**。
   7.4 更进一步：连"遍历 folio 逐段切分"也交给 iomap 框架，
   fileio 只剩 `iomap_read_ops` 两个回调——把 MAPPED 区间变成对文件的读。
   这也是 `fileio.c` 只有 158 行的原因。

4. 被用作**文件内偏移 ÷ 512**（即"文件内的扇区号"）。
   因为 `bio` 只有 `bi_sector` 这个位置字段，没有字节偏移；
   复用它比改结构划算。提交时再 `<< SECTOR_SHIFT` 换回字节。
   代价：这个 bio 不能交给块设备层。

5. 对应两个持有者：**提交方**与**完成回调**。谁最后 `refcount_dec_and_test()`
   谁负责 `kfree`。改成 1 会让先结束的一方释放后，另一方访问已释放内存（use-after-free）。

6. `bio_add_folio()` 返回失败 → 先把当前 `rq` 提交掉（`submit_read`），
   再开一个新的 `rq` 继续加。所以总量不受 16 限制，16 只是**单次请求**的上限。

7. 区分 bio 的来源：
   - `bi_end_io == NULL` → iomap 数据路径，逐段调 `iomap_finish_folio_read()`，
     由 iomap 账本决定何时真正结束 folio
   - `bi_end_io != NULL` → 元数据路径（`erofs_fileio_meta_endio`），
     只更新 `bi_status`，由 meta_endio 对每个 folio 直接 `folio_end_read()`

8. 三种：`IOMAP_HOLE`（空洞）→ `folio_zero_range()` **填零**；
   `IOMAP_INLINE`（尾部内联/META）→ `iomap_read_inline_data()` 直接 memcpy；
   `IOMAP_MAPPED`（正常映射）→ 调 `read_folio_range` 发底层 I/O。
   空洞就是"没有映射"，读出来全零。

9. 避免**双重页缓存**——镜像文件本身会被页缓存，EROFS 的内容又会进页缓存，
   同一份数据存两份。`O_DIRECT` 让读镜像文件时绕过第一层。

10. 因为读路径入口（`erofs_read_folio()` / `z_erofs_read_folio()`）就调用了
    `erofs_real_inode()`，说明 fileio 在设计时就考虑了 ishare。两者分工不同：
    fileio 决定"从哪个文件读"，ishare 决定"用谁的页缓存"。

11. 判据（`erofs_sb_share_test_super()`）：两边 `dif0.file` 指向同一 inode、
    `fsoffset` 相同、挂载选项 `opt` 逐字节相同，且旧 sb 未在退役。
    只对 fileio 有意义，因为"同一镜像"的判据建立在 `file_inode()` 上；
    块设备路径的同一设备由 VFS 的 bdev 挂载机制天然去重，不需要这个选项。

</details>

## 参考

[linux-stable (v7.4-rc1 a804c5742bff)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)
