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
  - ai
---

# 09 · 特性专题：文件后端（file-backed image / fileio）

> 对应配置：`CONFIG_EROFS_FS_BACKED_BY_FILE`
> 主源码：`fileio.c`（不到200行，是 EROFS 里最小的特性文件之一）
>
> 本文回答六个问题：**为什么需要它**（缘由）→ **为什么会这样设计**（理念）→
> **它长什么样**（架构）→ **用到哪些结构体** → **关键函数在做什么** →
> **一次读的完整来龙去脉**。

## 本专题目标（读完你应该能做到什么）

1. 说清"文件后端"解决的是什么场景问题，以及**为什么不能简单用 loop 设备**
2. 解释 EROFS 怎么做到"用读文件的方式读一个块设备镜像"
3. 看懂 `erofs_fileio_rq` 里 **refcount 为什么初始为 2**
4. 解释 `bi_sector` 在这个文件里被**挪用**成了什么（这是全篇最巧妙的一处）
5. 说清 `erofs_fileio_aops` 与常规 `erofs_aops` 的分工与切换时机
6. 独立读懂 `fileio.c` 的任意一行

> 若你对 `bio` 不熟，只需知道：**内核用 `bio` 描述一次块设备的 I/O**，
> 里面带"从哪个扇区开始、读写多少、数据放哪些页"。


## 一、特性缘由：为什么需要文件后端

#### 1.1 正常情况：镜像挂在块设备上

EROFS 是只读文件系统，最常见的用法是：

```
镜像文件 (xxx.erofs)  ──loop 设备──►  当块设备挂载
```

`mount -o loop -t erofs xxx.erofs /mnt` 就是这样：  
内核把文件"伪装"成块设备，
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

## 二、设计理念

#### 理念 1：不重写读路径，只替换"最后一公里"

EROFS 的读路径前面大部分（VFS → `erofs_map_blocks` 翻译出物理地址）
**与后端无关**。  
真正需要区分的只有最后一步：**怎么把物理地址处的数据读进来**。

所以 fileio 的设计是：

- **保留**全部映射逻辑（`erofs_map_blocks` / `erofs_map_dev` 照用）
- **只替换**"提交 I/O"这一步

这体现在代码组织上：`fileio.c` 只有不到200行——因为它只负责最后那一小段。

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
io->rq->bio.bi_iter.bi_sector =
        (io->dev.m_dif->fsoff + io->dev.m_pa) >> 9;      /* ÷512 */
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
        erofs_fileio_aops（文件后端的操作集）
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
  erofs_map_blocks  erofs_map_dev  erofs_fileio_rq
  （翻译地址）    （定位具体文件） （发起文件读）
        │                              │
        │                              ▼
        │                   vfs_iocb_iter_read()
        │                              │
        └──────────────────────────────┘
                     │
                     ▼
              镜像文件（普通文件）
```

#### 3.2 `aops` 的选择：`erofs_get_aops()`

`aops`（`address_space_operations`）是"怎么读一页"的回调集合。
EROFS 一共定义了 **4 套**：

| aops | 定义位置 | 用途 |
|---|---|---|
| `erofs_aops` | `data.c` | 常规非压缩（块设备） |
| `erofs_fileio_aops` | `fileio.c` | **文件后端** |
| `z_erofs_aops` | `zdata.c` | 压缩路径 |
| `z_erofs_cache_aops` | `zdata.c` | managed cache（压缩数据缓存，不对外暴露） |

选择逻辑在 `erofs_get_aops()`（`internal.h`），是**三级判断**：

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
	if (IS_ENABLED(CONFIG_EROFS_FS_BACKED_BY_FILE) &&
	    erofs_is_fileio_mode(EROFS_SB(realinode->i_sb)))
		return &erofs_fileio_aops;               /* ② 文件后端 */
	return &erofs_aops;                              /* ③ 常规 */
}
```

要点：

1. **压缩的判断在最前面** —— 所以压缩文件即便跑在文件后端上，  
   也先走 `z_erofs_aops`，由压缩路径内部再决定是否用 fileio 提交底层 I/O。
2. 只有**非压缩 + 文件后端模式**才直接选 `erofs_fileio_aops`。
3. 调用点在 `erofs_fill_inode()`（`inode.c`）里：  
   `aops = erofs_get_aops(inode); inode->i_mapping->a_ops = aops;`

> 📌 顺带澄清一个容易误记的点：**EROFS 没有 `erofs_fsdax_aops` 这样的东西**。  
>
> FSDAX 不走 `aops`，而是走 **`vm_operations_struct`**（`erofs_dax_vm_ops`，
> 在 `data.c`）配合 `dax_iomap_rw()`。  
>
> 详见 FSDAX 专题。

#### 3.3 一次读的完整流程

```
① VFS 要读某页 → 调用 erofs_fileio_read_folio()（或 readahead）

② 取 realinode
   erofs_real_inode(folio_inode(folio), &need_iput)
   └ 若启用了 ishare，真实数据可能在另一个 inode 上（见 11 专题）

③ erofs_fileio_scan_folio(&io, realinode, folio)
   ├ 循环处理 folio 内的每一段
   ├ erofs_map_blocks() → 得到 m_pa / m_llen / m_deviceid
   ├ erofs_map_dev()   → 得到具体文件 m_dif->file + 偏移
   └ 按三种情况分别处理：
        ├ EROFS_MAP_META   → 数据在元数据区，直接 memcpy
        ├ !MAPPED（空洞）  → folio_zero_segment() 填零
        └ 正常映射         → 加入 io->rq 的 bio

④ erofs_fileio_rq_submit(io.rq)
   ├ ki_pos = bi_sector << 9        ← 扇区换回字节偏移
   ├ iov_iter_bvec(...)             ← bio 的页转成 iov_iter
   └ vfs_iocb_iter_read()           ← 真正去读文件

⑤ 完成回调 erofs_fileio_ki_complete()
   ├ 逐 folio 结束（erofs_onlinefolio_end）
   ├ bio_endio() / bio_uninit()
   └ refcount_dec_and_test() → 释放 rq
```

## 四、关键结构体

#### 4.1 `struct erofs_fileio_rq`（`fileio.c`）

**一次文件读请求的载体**。这是本特性的核心结构体。

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

##### 为什么 `ref` 初始为 2 ？

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

**一次 folio 扫描的上下文**（栈上变量，不分配）：

```c
struct erofs_fileio {
	struct erofs_map_blocks map;   /* 当前映射结果 */
	struct erofs_map_dev dev;     /* 当前解析出的设备/文件 */
	struct erofs_fileio_rq *rq;   /* 正在累积的请求 */
};
```

它是**跨 folio 复用**的：`readahead` 时多个 folio 连续调用 `scan_folio`，  
只要它们的物理位置连续（`m_pa` 接得上），就**继续往同一个 `rq` 里加页**——
这就是 I/O 聚合。

看这段判断（决定是否要换一个新 `rq`）：

```c
if (io->rq && (map->m_pa + ofs != io->dev.m_pa ||
               map->m_deviceid != io->dev.m_deviceid)) {
io_retry:
        erofs_fileio_rq_submit(io->rq);   /* 位置不连续 → 先提交旧的 */
        io->rq = NULL;
}
```

⇒ **物理连续就合并，不连续就切开**。这是 I/O 优化的标准做法。

#### 4.3 相关的通用结构体（详见 08 专题）

| 结构体 | 在这里的作用 |
|---|---|
| `erofs_map_blocks` | `m_pa`（物理地址）、`m_la`、`m_llen`、`m_deviceid`、`m_flags` |
| `erofs_map_dev` | 解析出具体文件：`m_dif->file` 与 `m_pa` |
| `erofs_device_info` | `file` 字段——**镜像文件就在这里**；`fsoff` 是本设备内偏移 |

## 五、主要函数

#### 5.1 对外接口（被其他文件调用）

| 函数 | 作用 |
|---|---|
| `erofs_fileio_bio_alloc()` | 分配一个"伪装成 bio"的 `erofs_fileio_rq`，返回它的 `bio` |
| `erofs_fileio_submit_bio()` | 提交：不交给块设备，而是转成文件读 |

这两个函数是**fileio 与外界的唯一接口**——它们的命名刻意与块设备接口一致
（`bio_alloc` / `submit_bio`），这样上层代码不用改。

#### 5.2 内部函数

###### `erofs_fileio_rq_alloc()` —— 分配与初始化

```c
struct erofs_fileio_rq *rq = kzalloc_obj(...);
bio_init(&rq->bio, NULL, rq->bvecs, ARRAY_SIZE(rq->bvecs), REQ_OP_READ);
rq->iocb.ki_filp = mdev->m_dif->file;    /* ← 要读的文件 */
rq->sb = mdev->m_sb;
refcount_set(&rq->ref, 2);
```

要点：
- `bio_init()` 时 **不设 `bi_end_io`**（为 NULL）—— 这个细节在 5.3 会用到
- `ki_filp` 直接指向镜像文件

###### `erofs_fileio_rq_submit()` —— 提交（关键）

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

###### `erofs_fileio_ki_complete()` —— 完成回调

```c
if (ret >= 0 && ret != rq->bio.bi_iter.bi_size)
        ret = -EIO;                        /* 读到的长度不对 → 报错 */

if (!rq->bio.bi_end_io) {                  /* ★ 没有 bi_end_io = fileio 自己管的 */
        bio_for_each_folio_all(fi, &rq->bio) {
                DBG_BUGON(folio_test_uptodate(fi.folio));
                erofs_onlinefolio_end(fi.folio, ret < 0, false);
        }
} else if (ret < 0 && !rq->bio.bi_status) {
        rq->bio.bi_status = errno_to_blk_status(ret);
}
bio_endio(&rq->bio);
bio_uninit(&rq->bio);
if (refcount_dec_and_test(&rq->ref))
        kfree(rq);
```

**`if (!rq->bio.bi_end_io)` 这一句很关键**：

它区分了两种情况——

- `bi_end_io == NULL`：**这是 fileio 自己构造的 bio**，
  由 fileio 自己遍历 folio 结束 I/O
- `bi_end_io != NULL`：bio 来自别处（有块设备层的完成回调），
  只更新状态，让原有流程继续

这是一种"**同一个函数兼容两种来源**"的写法。

###### `erofs_fileio_scan_folio()` —— 扫描一个 folio

这是主体逻辑，处理三种情况：

| 情况 | 判断 | 处理 |
|---|---|---|
| 数据在元数据区 | `m_flags & EROFS_MAP_META` | `erofs_read_metabuf()` + `memcpy_to_folio()` |
| 空洞（未映射） | `!(m_flags & EROFS_MAP_MAPPED)` | `folio_zero_segment()` 填零 |
| 正常映射 | 其余 | 加入 `io->rq->bio` |

其中"正常映射"分支还会做**连续性与容量检查**：

```c
if (!bio_add_folio(&io->rq->bio, folio, len, cur))
        goto io_retry;      /* bio 满了（16 个 bvec）→ 先提交，再来 */
if (!attached++)
        erofs_onlinefolio_split(folio);
io->dev.m_pa += len;        /* 推进，供下次连续性判断 */
```

#### `erofs_fileio_read_folio()` / `readahead()` —— 入口

两者都遵循同一个模式：

```c
realinode = erofs_real_inode(folio_inode(folio), &need_iput);
struct erofs_fileio io = {};        /* 栈上上下文 */
err = erofs_fileio_scan_folio(&io, realinode, folio);
erofs_fileio_rq_submit(io.rq);      /* 收尾：提交剩余 */
if (need_iput)
        iput(realinode);
```

注意 **`erofs_real_inode()`** 的调用:  
fileio 同样要处理 ishare 的情况
（真实 inode 可能是另一个），这说明**文件后端与 page cache sharing 会叠加使用**。

## 六、来龙去脉：完整串一遍

假设容器里要读 EROFS 镜像中的某个文件第一页：

```
① 容器没有 loop 权限，但能打开镜像文件
        │
② 挂载时 EROFS 发现后端是文件（m_dif->file 非空）
        └─ 该 inode 的 aops 选 erofs_fileio_aops
        │
③ 进程 read() → VFS 发现页不在缓存 → 调 read_folio
        │
④ erofs_fileio_read_folio()
        ├ erofs_real_inode() 取真实 inode（ishare 时可能换）
        └ erofs_fileio_scan_folio()
        │
⑤ scan_folio 内：
        ├ erofs_map_blocks() → m_pa（镜像内偏移）、m_deviceid
        ├ erofs_map_dev()    → 找到 m_dif->file（镜像文件）+ fsoff
        └ bio_add_folio()    → 把目标页加进 rq->bio
        │
⑥ erofs_fileio_rq_submit()
        ├ ki_pos = bi_sector << 9     ← 扇区号还原成文件偏移
        ├ iov_iter_bvec()             ← bio 的页 → iov_iter
        └ vfs_iocb_iter_read()        ← 读！不再经过块设备
        │
⑦ 文件读完成 → ki_complete 回调
        ├ 遍历 bio 里的 folio，逐个 erofs_onlinefolio_end()
        └ refcount 减到 0 → kfree(rq)
        │
⑧ 页变成 uptodate → read() 返回数据
```

**整条链上没有出现块设备层**，这就是文件后端的本质。

## 七、动手验证

#### 验证 1：确认配置是否启用

```bash
grep EROFS_FS_BACKED_BY_FILE /home/linux/linux-stable/.config
# CONFIG_EROFS_FS_BACKED_BY_FILE=y
```

### 验证 2：看 fileio 的操作集被注册在哪

```bash
cd /home/linux/linux-stable/fs/erofs
grep -rn "erofs_fileio_aops" .
```

应该能看到它在 `inode.c`（或 `super.c`）里按后端类型被选中——
**对照一下选中条件**，就能确认"什么时候走文件后端"。

### 验证 3：在 QEMU 里实测文件后端挂载

这是最有说服力的验证（需要镜像文件而非块设备）：

```bash
# VM 内
mkdir -p /mnt/f
mount -t erofs -o backed_file /host/plain.erofs /mnt/f   # 具体挂载选项见源码
cat /mnt/f/big.bin | head -c 100
dmesg | grep -i erofs
```

> 挂载选项的确切写法请以源码里 `erofs_fs_context` / `fs_context_operations`
> 解析 `opt` 的部分为准（在 `super.c` 里搜索相关字符串）。
> 由于版本演进，本文不写死某个选项名。

### 验证 4：观察是否真的绕过了块设备

若挂载成功且能读数据，而**没有**创建任何 loop 设备，即证明走的是文件后端：

```bash
losetup -a      # 应看不到与本次挂载相关的 loop 设备
```

## 八、常见误解（重要）

### 误解 1：文件后端就是把镜像当普通文件读，所以性能一定差

不对。它**仍然可以聚合 I/O**（一次 `rq` 最多 16 个 bvec），
也**可以用 `O_DIRECT`** 绕过双重缓存。
真正的差异在于少了块设备层的一层转换——某些场景反而更快。

### 误解 2：`bvecs[16]` 意味着一次只能读 16 个页

不完全对。16 是**一次 `bio` 的 bvec 上限**；
`readahead` 会在 bio 满时**先提交、再开新的**（`goto io_retry`），
所以总量不受 16 限制。

### 误解 3：`bi_sector` 还是扇区号

在 `fileio.c` 里**不是**。它被用作"文件内偏移 ÷ 512"，
提交时再乘回来。**这个 bio 绝不能交给块设备层**。

### 误解 4：`refcount` 初始为 2 是笔误

不是。它对应"提交方"和"完成回调"两个持有者，
谁最后结束谁释放。改成 1 会导致 use-after-free。

### 误解 5：文件后端与 ishare 互斥

不互斥。`erofs_fileio_read_folio()` 里就调用了 `erofs_real_inode()`，
说明**两者可以叠加**——文件后端提供"从哪读"，ishare 决定"用谁的页缓存"。

## 九、与其他特性的关系

| 特性 | 关系 |
|---|---|
| **ishare / page cache sharing**（11 专题） | 可叠加。fileio 的入口就调用了 `erofs_real_inode()` |
| **FSDAX**（10 专题） | 另一种"绕开块设备/页缓存"的方案，思路不同但目标相近 |
| **多设备** | fileio 也走 `erofs_map_dev()`，所以多设备逻辑**照常工作**（每个设备可以是各自的镜像文件） |
| **压缩路径** | 压缩数据的读取也走同一套后端抽象，`z_erofs_submit_bio` 类接口会分发到 fileio |
| **DIRECT_IO 选项** | fileio 专用优化，避免双重页缓存 |

## 自测检查点

1. 文件后端解决什么问题？举一个 loop 设备不可用的场景。
2. `bdev` 与 `fileio` 分别指什么？
3. 为什么 fileio 不重写整个读路径？它替换的是哪一步？
4. `bi_sector` 在 fileio 里被当成什么用？为什么要这样绕？
5. `erofs_fileio_rq.ref` 为什么初始为 2？改成 1 会怎样？
6. `bvecs[16]` 满了之后怎么办？
7. `erofs_fileio_ki_complete()` 里 `!rq->bio.bi_end_io` 这个判断在区分什么？
8. scan_folio 处理的三种情况分别是什么？空洞怎么表示？
9. `DIRECT_IO` 选项在 fileio 里解决什么问题？
10. 为什么说文件后端与 ishare 可以叠加？

## 自测答案

<details>
<summary>点击展开</summary>

1. 解决"镜像是文件但无法/不便用 loop 设备"的问题。  
   典型场景：**容器内部**没有创建loop 设备的权限（需要 `CAP_SYS_ADMIN`）。  
   此外还有嵌套挂载、无特权环境、loop 数量受限。

2. `bdev` = block device 后端（常规，镜像挂在块设备上）；  
   `fileio` = 文件后端（直接 VFS 读镜像文件）。

3. 因为前面大半（VFS → `erofs_map_blocks` 翻译物理地址）**与后端无关**。  
   fileio 只替换"提交 I/O"这最后一步——这也是 `fileio.c` 只有 196 行的原因。

4. 被用作**文件内偏移 ÷ 512**（即"文件内的扇区号"）。  
   因为 `bio` 只有 `bi_sector` 这个位置字段，没有字节偏移；  
   复用它比改结构划算。提交时再 `<< SECTOR_SHIFT` 换回字节。  
   代价：这个 bio 不能交给块设备层。

5. 对应两个持有者：**提交方**与**完成回调**。谁最后 `refcount_dec_and_test()`
   谁负责 `kfree`。  
   改成 1 会让先结束的一方释放后，另一方访问已释放内存（use-after-free）。

6. `bio_add_folio()` 返回失败 → `goto io_retry`：先把当前 `rq` 提交掉，
   再开一个新的 `rq` 继续加。  
   所以总量不受 16 限制，16 只是**单次 bio**的上限。

7. 区分 bio 的来源：
   - `bi_end_io == NULL` → fileio 自己构造的，由 fileio 自己遍历 folio 收尾  
   - `bi_end_io != NULL` → 来自别处（有块设备层回调），只更新 `bi_status`，让原流程继续

8. 三种：① `EROFS_MAP_META`（数据在元数据区）→ `erofs_read_metabuf()` + memcpy；  
   ② 未映射（空洞）→ `folio_zero_segment()` **填零**；  
   ③ 正常映射 → 加入 `rq->bio`。空洞就是"没有映射"，读出来全零。  

9. 避免**双重页缓存**——镜像文件本身会被页缓存，EROFS 的内容又会进页缓存，  
   同一份数据存两份。`O_DIRECT` 让读镜像文件时绕过第一层。

10. 因为 `erofs_fileio_read_folio()` 里就调用了 `erofs_real_inode()`，  
    说明 fileio 在设计时就考虑了 ishare。两者分工不同：  
    fileio 决定"从哪个文件读"，ishare 决定"用谁的页缓存"。

</details>

## 参考
[linux-7.2](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
[EROFS 官方文档 Release 0.1](https://erofs.docs.kernel.org)
