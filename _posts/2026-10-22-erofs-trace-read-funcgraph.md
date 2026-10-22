---
layout:     post
title:      EROFS trace read funcgraph
subtitle:   EROFS 跟踪读调用路径
date:       2026-10-22
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
---

# EROFS read 流程追踪

内容分两部分，两者除「镜像怎么挂」之外，追踪手法完全一致：

- **实验 A** — fileio（文件后端）read 路径
- **实验 B** — bdev（块设备）read 路径

> **版本说明（2026-10-22 重测）**
> 本文全部数据在 **7.4-rc1 合并窗口之后**的内核上重新实测：
> 源码树 `/home/linux/erofs/linux-stable`，HEAD `a804c5742bff`，
> `kernel.release = 7.3.0-01703-ga804c5742bff`。
>
> 7.4 的 fileio 大重构（`1137aa577a35`，fileio 数据读改用 iomap 回调）之后，
> **实验 A 与实验 B 的前半段在 trace 里逐帧一致**——`erofs_fileio_readahead` /
> `erofs_fileio_scan_folio` / `erofs_fileio_aops` 已全部删除，
> 分叉点从「选哪套 a_ops」下移为「iomap 框架里选哪个 `iomap_read_ops`」。
> 凡与旧版（`v7.3-rc3-60`）数据冲突之处，以本文 7.4 数据为准；
> 旧数据只保留在 §2.4 的对照表里。

## 0. 环境 / 前提

| 项 | 值 |
|---|---|
| VM 内核 | `/home/linux/erofs/linux-stable`，`7.3.0-01703-ga804c5742bff`（7.4-rc1 合并窗口后）<br>`CONFIG_FUNCTION_TRACER` / `FUNCTION_GRAPH_TRACER` / `DYNAMIC_FTRACE` 均为 `y` |
| VM 内核镜像 | `/home/linux/erofs/linux-stable/arch/x86/boot/bzImage` |
| VM initrd | `/home/linux/erofs/erofs-boot-initrd.img` |
| VM 根文件系统 | `/home/linux/erofs/erofs-rootfs-ext4.img`（ext4，内含 busybox + `mount.erofs`） |
| 被测 EROFS 镜像 | `/home/linux/erofs/img-stable/test/images/plain.erofs`<br>内含 `big.bin`（100000 字节）/ `tiny.txt` |
| 9p 共享 | `-virtfs local,path=/home/linux/erofs,mount_tag=host`<br>⇒ 宿主机 `/home/linux/erofs` == VM 内 `/host` |

VM 根文件系统的 `/init` 里已挂好 tracefs：

```sh
mount -t tracefs nodev /sys/kernel/tracing
```

## 1. 宿主机侧准备

把两个脚本写进 VM 镜像

```bash
# 1.1 挂载 ext4 根文件系统镜像（注意：必须 umount，否则 QEMU 拿不到写锁）
mount -o loop /home/linux/erofs/erofs-rootfs-ext4.img /mnt/rt

# 1.2 写脚本
cat /home/linux/erofs/trace-graph/trace-read-fileio.sh > /mnt/rt/trace-read-fileio.sh
cat /home/linux/erofs/trace-graph/trace-read-bdev.sh   > /mnt/rt/trace-read-bdev.sh
chmod +x /mnt/rt/trace-read-fileio.sh /mnt/rt/trace-read-bdev.sh
sh -n /mnt/rt/trace-read-fileio.sh && sh -n /mnt/rt/trace-read-bdev.sh   # 语法自检

# 1.3 卸载（关键！不卸载 QEMU 会报
#     "Failed to get 'write' lock / Is another process using the image"）
sync && umount /mnt/rt

# 1.4 跑之前确认环境干净
pgrep -c qemu-system ; mount | grep erofs-rootfs
# 两者都应为 0，否则上一次的 VM 还占着镜像
```

## 2. 实验 A：fileio（文件后端）read 路径

#### 2.1 启动命令（宿主机）

```bash
cd /home/linux/erofs/linux-stable

qemu-system-x86_64 -m 8192 -smp 4 -nographic \
  -kernel arch/x86/boot/bzImage --enable-kvm \
  -initrd /home/linux/erofs/erofs-boot-initrd.img \
  -append "console=ttyS0 rdinit=/init" \
  -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
  -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
  -monitor none -no-reboot
```

若要把输出留档（自动化时）：

```bash
( sleep 25 ; echo '/trace-read-fileio.sh __x64_sys_read' ; \
  echo 'echo MARK_SCRIPT_DONE' ; echo 'poweroff -f' ) | \
  timeout 280 qemu-system-x86_64 ... > /home/linux/erofs/trace-graph/trace-read-fileio-raw-74.log 2>&1
```

> `sleep 25` 是等 VM 起来，否则第一行命令会被吞掉。
> 末尾补 `poweroff -f`：脚本跑完 VM 自己关机，不必干等 280 秒超时（KVM 下全程约 45 秒）。

#### 2.2 VM 内命令

等价的手工版（脚本做的事就是这些）：

```sh
cd /sys/kernel/tracing
mount.erofs /host/img-stable/test/images/plain.erofs /mnt/plain
echo 0 > tracing_on; echo > trace; echo > set_graph_function
echo > set_graph_notrace; echo > set_ftrace_filter; echo > set_ftrace_notrace
echo 8192 > buffer_size_kb
echo function_graph > current_tracer
echo __x64_sys_read >> set_graph_function
echo 3 > /proc/sys/vm/drop_caches          # ★ 保证冷读
echo 1 > tracing_on
dd if=/mnt/plain/big.bin of=/dev/null bs=4096 count=16 2>/dev/null
echo 0 > tracing_on
cat trace
```

#### 2.3 脚本（`/trace-read-fileio.sh`）

完整内容见 `trace-graph/trace-read-fileio.sh`（7.3 时代的原始版本见
[2026-09-16-erofs-trace-read-fileio.sh](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-16-erofs-trace-read-fileio.sh)），
核心片段：

```sh
FUNCTION=$1
IMG=/host/img-stable/test/images/plain.erofs
MNT=/mnt/plain
TRACING_DIR=/sys/kernel/tracing

cd $TRACING_DIR || exit 1

# 1. 确保镜像已挂载
mount | grep -q "$MNT" || mount.erofs $IMG $MNT
mount | grep -F "$MNT"

# 2. 停止追踪并清空
echo 0 > tracing_on
echo > trace
echo > set_graph_function
echo > set_graph_notrace
echo > set_ftrace_filter
echo > set_ftrace_notrace

# ---- 阶段 0：探测哪些函数真的能被 ftrace 抓到 ----
# （7.4 起两个实验用同一份 20 函数清单，方便横向对比；
#   阶段 0 也放大缓冲，否则 function tracer 全量记录会绕圈）
echo 8192 > buffer_size_kb
echo function > current_tracer
echo > trace
echo 3 > /proc/sys/vm/drop_caches
echo 1 > tracing_on
dd if=$MNT/big.bin of=/dev/null bs=4096 count=16 2>/dev/null
echo 0 > tracing_on
echo "@@@@@@ PROBE @@@@@@"
for f in __x64_sys_read vfs_read ksys_read new_sync_read erofs_file_read_iter \
         filemap_read erofs_read_folio erofs_readahead iomap_readahead \
         erofs_iomap_begin iomap_read_folio_iter erofs_map_blocks erofs_map_dev \
         submit_bio vfs_iocb_iter_read \
         erofs_fileio_iomap_read_folio_range erofs_fileio_rq_submit \
         erofs_fileio_ki_complete erofs_fileio_readahead erofs_fileio_scan_folio; do
    echo "PROBE_$f=$(grep -c "$f" trace)"
done
echo "@@@@@@ PROBE END @@@@@@"

# ---- 阶段 1：正式抓调用图 ----
echo nop > current_tracer
echo > set_ftrace_filter
echo > set_graph_function
echo 8192 > buffer_size_kb
echo function_graph > current_tracer
echo "${FUNCTION:-__x64_sys_read}" >> set_graph_function

echo 0 > options/funcgraph-irqs
echo 1 > options/funcgraph-proc
echo 1 > options/funcgraph-tail
echo 1 > options/funcgraph-abstime

# 过滤无关函数（约 40 行 echo ... >> set_graph_notrace，见脚本原文）

# ---- 开抓 ----
echo > trace
echo 3 > /proc/sys/vm/drop_caches
echo 1 > tracing_on
dd if=$MNT/big.bin of=/dev/null bs=4096 count=16 2>/dev/null
echo 0 > tracing_on

echo "@@@@@@ GRAPH BEGIN @@@@@@"
cat trace
echo "@@@@@@ GRAPH END @@@@@@"
```

#### 2.4 PROBE 结果（7.4 实测）

> 阶段 0 是**全系统**的 function tracer 计数：只回答「这个函数能不能被 ftrace 抓到、
> 有没有在 dd 窗口里跑过」，数值含其他进程与后台 IO，只能定性（0 vs 非 0），
> 精确结构以阶段 1 的图为准（见 §5 注意事项 9）。

```
PROBE___x64_sys_read=18
PROBE_vfs_read=92
PROBE_ksys_read=54
PROBE_new_sync_read=0            ← 同 TU 被内联，抓不到
PROBE_erofs_file_read_iter=16    ← dd bs=4096 count=16 ⇒ 正好 16 次 read()
PROBE_filemap_read=103
PROBE_erofs_read_folio=3         ★ 7.3 是 0：fileio 现在共用 erofs_aops
PROBE_erofs_readahead=9          ★ 7.3 是 0：同上
PROBE_iomap_readahead=42         ★ 7.4 新增探测：fileio 也走 iomap 框架
PROBE_erofs_iomap_begin=23       ★ 7.3 是 0：地址翻译同样经过它
PROBE_iomap_read_folio_iter=162  ★ 框架逐段切分 folio 的主循环
PROBE_erofs_map_blocks=7
PROBE_erofs_map_dev=6
PROBE_submit_bio=470             ⚠ 全是 rootfs ext4（/dev/vda）后台 IO，见 §5-9；
                                   图内（EROFS 路径）实测 0
PROBE_vfs_iocb_iter_read=20      ★ fileio 的最后一公里
PROBE_erofs_fileio_iomap_read_folio_range=54   ★ fileio 专属回调
PROBE_erofs_fileio_rq_submit=8
PROBE_erofs_fileio_ki_complete=62              ★ 完成回调在跑（异步，不进图）
PROBE_erofs_fileio_readahead=0   ★ 函数已删除，确认抓不到
PROBE_erofs_fileio_scan_folio=0  ★ 函数已删除，确认抓不到
```

与 7.3 旧数据对照（同一份 dd 命令、同一台 VM 手法）：

| PROBE | 7.3 fileio | 7.4 fileio | 说明 |
|---|---|---|---|
| `erofs_read_folio` | 0 | **3** | 7.4 起 fileio 共用 `erofs_aops` |
| `erofs_readahead` | 0 | **9** | 同上 |
| `erofs_iomap_begin` | 0 | **23** | 地址翻译并入 iomap 框架 |
| `iomap_readahead` | （未探测） | **42** | fileio 也走通用框架 |
| `erofs_fileio_readahead` | 3 | **0** | 函数已删除 |
| `erofs_fileio_scan_folio` | （图内可见） | **0** | 函数已删除 |
| `erofs_map_dev` | 2 | 6 | 元数据路径现在每个 meta folio 都过它 |
| `submit_bio` | （未探测） | 470 | 全系统计数，均为 rootfs 噪声（图内 0） |

#### 2.5 提炼出的读路径栈（fileio，v7.4）

[完整graph-trace栈](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-22-erofs-trace-graph-fileio-74.txt)

```text
__x64_sys_read() {                          ← 根函数（不能用 do_mount/vfs_read 那类）
  ksys_read() {
    vfs_read() {
      erofs_file_read_iter() {              ← fs/erofs/data.c：入口三分支
        filemap_read() {                    ← 因非 DAX、非 DIO，落到缓冲读
          filemap_get_pages() {
            page_cache_sync_ra() {          ← 首次访问，同步预读
              page_cache_ra_order() {
                do_page_cache_ra() {
                  page_cache_ra_unbounded() {
                    read_pages() {
                      erofs_readahead() {               ★ fs/erofs/data.c
                        erofs_real_inode();             ← ishare 叠加点
                        iomap_readahead() {             ← 内核通用 iomap 框架
                          iomap_iter() {
                            erofs_iomap_next() {
                              erofs_iomap_begin.constprop.0() {
                                erofs_map_blocks();   ← m_pa / m_llen / m_deviceid
                                erofs_map_dev();      ← 解析出 m_dif->file（镜像文件）
                              }                        ← 以上与 bdev 实验逐帧一致
                            }
                          }
                          iomap_read_folio_iter() {     ← 框架逐段切分一个 folio
                            ifs_alloc.isra.0();
                            iomap_adjust_read_range();
                            erofs_fileio_iomap_read_folio_range() {   ★ fileio 唯一专用回调
                              erofs_fileio_rq_alloc() {  ← refcount 置 2
                                bio_init();
                              }
                              bio_add_folio_nofail();    ← 段连续就合并进同一个 rq
                            }                            ← 实测 24 次（3 个 readahead 突发）
                          }
                          erofs_fileio_rq_submit() {     ★ 每个突发末尾提交一次（实测 3 次）
                            vfs_iocb_iter_read() {       ← 不经过块设备层
                              rw_verify_area();
                              v9fs_file_read_iter() {    ← 镜像文件在 9p 共享上
                                netfs_unbuffered_read_iter() { ... }
```

图里还能看到的两个细节：

- **INLINE 段由框架处理**：`big.bin` 的尾巴是 tail-packing 内联数据，
  图中出现 `iomap_read_inline_data()`（2 次）——7.4 起 fileio 不再需要自己管内联。
- **完成回调不在图里**：`erofs_fileio_ki_complete()` / `iomap_finish_folio_read()`
  在图内 0 次。`vfs_iocb_iter_read()` 返回 `-EIOCBQUEUED`，真正的完成由 9p/netfs
  的完成上下文异步触发（阶段 0 全系统计数 62 次证明它确实在跑）。

**一句话**：EROFS 自己的代码只到「攒 rq」为止；`vfs_iocb_iter_read()` 把「镜像文件」
当普通文件读，整条链上没有 `submit_bio`（图内实测 0 次），不经过块设备层。
这正是 09 专题 §3.3 的结论。

## 3. 实验 B：bdev（块设备）read 路径

#### 3.1 启动命令（宿主机）—— 比 A 多挂一块盘

```bash
cd /home/linux/erofs/linux-stable

qemu-system-x86_64 -m 8192 -smp 4 -nographic \
  -kernel arch/x86/boot/bzImage --enable-kvm \
  -initrd /home/linux/erofs/erofs-boot-initrd.img \
  -append "console=ttyS0 rdinit=/init" \
  -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
  -drive file=/home/linux/erofs/img-stable/test/images/plain.erofs,format=raw,if=virtio \
  -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
  -monitor none -no-reboot
```

第二块 `-drive` 让 EROFS 镜像成为 VM 里的 `/dev/vdb`（真正的 virtio-blk）。内核启动时会打印：

```
virtio_blk virtio2: [vdb] 200 512-byte logical blocks (102 kB/100 KiB)
```

#### 3.2 VM 内命令

```sh
cd /sys/kernel/tracing
mkdir -p /mnt/bdev
mount -t devtmpfs devtmpfs /dev            # ★ /init 没挂 /dev，必须补
ls -l /dev/vdb || mknod /dev/vdb b 254 16  # 兜底建节点（实测主设备号为 254）
mount -t erofs /dev/vdb /mnt/bdev
echo 0 > tracing_on; echo > trace; echo > set_graph_function
echo > set_graph_notrace; echo > set_ftrace_filter; echo > set_ftrace_notrace
echo 8192 > buffer_size_kb
echo function_graph > current_tracer
echo __x64_sys_read >> set_graph_function
echo 3 > /proc/sys/vm/drop_caches
echo 1 > tracing_on
dd if=/mnt/bdev/big.bin of=/dev/null bs=4096 count=16 2>/dev/null
echo 0 > tracing_on
cat trace
```

#### 3.3 脚本（`/trace-read-bdev.sh`）

与 fileio 版唯一差别在第 1 段（挂载方式），PROBE 清单 7.4 起两边统一
（完整内容见 `trace-graph/trace-read-bdev.sh`）：

```sh
FUNCTION=$1
IMG=/host/img-stable/test/images/plain.erofs
MNT=/mnt/bdev
DEV=/dev/vdb
TRACING_DIR=/sys/kernel/tracing

cd $TRACING_DIR || exit 1

# 1. 用真正的块设备挂载（保证走块设备路径）
#    ⚠️ 不要用 loop：这台 VM 的 /ko 模块是给别的内核编的（virtio_blk/mbcache/jbd2/ext4
#       全部 "invalid module format"），loop 挂上去读回来不对，内核报
#       "cannot find valid erofs superblock"。
#       ⇒ 改为把 erofs 镜像作为第二块 virtio-blk 直接挂进来（/dev/vdb）。
mkdir -p $MNT
mount | grep -q " /dev " || mount -t devtmpfs devtmpfs /dev
ls -l $DEV 2>/dev/null || mknod $DEV b 254 16
ls -l $DEV
mount | grep -q "$MNT" || mount -t erofs $DEV $MNT
mount | grep -F "$MNT"

# 2~4 段同 fileio 版（PROBE 清单一致）
```

#### 3.4 PROBE 结果（7.4 实测）

```
PROBE___x64_sys_read=18
PROBE_vfs_read=92
PROBE_ksys_read=54
PROBE_new_sync_read=0
PROBE_erofs_file_read_iter=16
PROBE_filemap_read=104
PROBE_erofs_read_folio=3
PROBE_erofs_readahead=9
PROBE_iomap_readahead=42
PROBE_erofs_iomap_begin=23
PROBE_iomap_read_folio_iter=162
PROBE_erofs_map_blocks=7
PROBE_erofs_map_dev=5
PROBE_submit_bio=546             ← 含 rootfs ext4 噪声；图内 EROFS 路径 9 次
PROBE_vfs_iocb_iter_read=0       ★ bdev 不用文件读接口
PROBE_erofs_fileio_iomap_read_folio_range=0   ★ fileio 回调完全不出现
PROBE_erofs_fileio_rq_submit=0
PROBE_erofs_fileio_ki_complete=0
PROBE_erofs_fileio_readahead=0   ← 函数已删除
PROBE_erofs_fileio_scan_folio=0  ← 函数已删除
```

注意前 13 行与实验 A **完全相同**——7.4 起两条路前半段就是同一份代码。

#### 3.5 提炼出的读路径栈（bdev，7.4）

[完整graph-trace栈](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-22-erofs-trace-graph-bdev-74.txt)

```text
__x64_sys_read() {
  ksys_read() {
    vfs_read() {
      erofs_file_read_iter() {              ← fs/erofs/data.c
        filemap_read() {
          filemap_get_pages() {
            page_cache_sync_ra() {
              page_cache_ra_order() {
                do_page_cache_ra() {
                  page_cache_ra_unbounded() {
                    read_pages() {
                      erofs_readahead() {            ★ 与 fileio 同一个函数
                        erofs_real_inode();
                        iomap_readahead() {
                          iomap_iter() {
                            erofs_iomap_next() {
                              erofs_iomap_begin.constprop.0() {   ★ 分叉前的地址翻译
                                erofs_map_blocks();   ← m_pa / m_deviceid
                                erofs_map_dev();      ← 解析出 iomap->bdev
                              }
                            }
                          }
                          iomap_read_folio_iter() {
                            ifs_alloc.isra.0();
                            iomap_adjust_read_range();
                            iomap_bio_read_folio_range() {   ★ bdev 一侧的回调
                              bio_alloc_bioset();     ← 构造 bio
                              bio_add_folio_nofail(); ← 把目标页挂进 bio
                            }                           ← 实测 48 次（3 个突发）
                          }
                          iomap_bio_submit_read() {   ← 实测 6 次
                            submit_bio() {           ★ 进入块设备层
                              __submit_bio() {
                                blk_mq_submit_bio() {
                                  ...
                                  virtio_queue_rqs()      ← 真正下发给 virtio-blk
```

**一句话**：`erofs_map_dev()` 填 `iomap->bdev`，之后由 iomap 框架的
`iomap_bio_read_ops` 回调构造 bio 并 `submit_bio()`，再经 blk-mq → virtio-blk 下发。
整条链上不出现 `vfs_iocb_iter_read()`（图内 0 次）。

## 4. 两条路对比（7.4，同一份 dd 命令，只有挂载方式不同）

| | fileio 挂载 | bdev 挂载 |
|---|---|---|
| 挂载命令 | `mount.erofs IMG /mnt/plain` | `mount -t erofs /dev/vdb /mnt/bdev` |
| `erofs_is_fileio_mode()` | 真（`dif0.file` 非空） | 假 |
| 选中的 `a_ops` | **`erofs_aops`** | **`erofs_aops`（同一套）** |
| `.readahead` | **`erofs_readahead`** | **`erofs_readahead`（同一个）** |
| 地址翻译 | `erofs_iomap_begin` → `map_blocks`/`map_dev` | 同左，逐帧一致 |
| 分叉点 | **`iomap_read_ops` 二选一**（`erofs_read_folio`/`erofs_readahead` 内，`data.c`） | 同左，选另一支 |
| `read_folio_range` 回调 | `erofs_fileio_iomap_read_folio_range` | `iomap_bio_read_folio_range` |
| 提交回调 | `erofs_fileio_iomap_submit_read` → `erofs_fileio_rq_submit` | `iomap_bio_submit_read` |
| 最后一步 | `vfs_iocb_iter_read()` | `submit_bio()` |
| 经过块设备层 | 否 | 是 |
| 图内 `submit_bio() {` | **0** | 9（6 次父帧是 `iomap_bio_submit_read`；其余 3 次是 drop_caches 后 rootfs ext4 重新调页 dd 自身代码，按父帧区分） |
| 图内 `vfs_iocb_iter_read() {` | 3 | **0** |
| 图内 fileio 回调 | 24 range / 3 submit | 0 |
| read 系统调用 | 16 | 16 |
| 图行数 | 3144 | 2622 |

⇒ 7.4 起，挂载源是「文件」还是「块设备」不再决定用哪套 a_ops（只有一套），
而是决定 `erofs_read_folio()`/`erofs_readahead()` 里 `read_ctx.ops` 选哪组
`iomap_read_ops`。两条路在 trace 里前半段逐帧一致，只在 `iomap_read_folio_iter()`
的回调里分开。见 09 专题 §3.2。

**7.3 → 7.4 的变化**（为什么旧版图里 fileio 长得多）：
7.3 的 fileio 有专用 aops，`erofs_fileio_readahead` → `erofs_fileio_scan_folio`
逐 folio 调 `erofs_onlinefolio_init/split/end` 自己数完成量（旧图 6065 行）；
7.4 把逐段切分、空洞填零、内联 memcpy、完成计数全部移交 iomap 框架，
fileio 只剩「攒 rq + 提交 + 完成回调」，图瘦到 3144 行，
顺带修复了旧版 len==0 时 folio 完成计数不平衡导致 soft lockup 的一类问题
（详见 `markdown/erofs-7.4-重新分析-fs-erofs源码变更与旧结论校正.md`）。

## 5. 注意事项

1. **根函数不能选「被内联」的函数**
   `do_mount`、`new_sync_read`、`do_new_mount` 都是 0 命中：  
   它们在 `/proc/kallsyms` 和 `System.map` 里都有符号，但 GCC 已把它们内联进调用者，ftrace 插桩的那份独立函数体运行时不会进入。  
   syscall 包装（`__x64_sys_*`）通常安全。脚本里的 PROBE 阶段就是用来逐个验证的。

2. **必须先 `drop_caches`**
   探测阶段读过一遍后页缓存就热了，第二次读只剩 236 行，`erofs_file_read_iter` 只花 4.3 µs。  
   加 `echo 3 > /proc/sys/vm/drop_caches` 后图从 236 行涨到几千行。

3. **`buffer_size_kb` 要放大（8192）**
   默认缓冲会被刷屏的读冲掉。7.4 版脚本在阶段 0 也加了这一步（阶段 0 的
   function tracer 是全量记录，比 function_graph 更费缓冲）。

4. **`set_graph_function` 一旦非空，function_graph 只记录以该函数为根的图**

5. **`/dev/vdb` 默认不存在**
   rootfs 的 `/init` 只挂了 proc / sys / tracefs / 9p，没挂 `/dev`。脚本里补 `mount -t devtmpfs devtmpfs /dev`，再兜底 `mknod`。

6. **`erofs_iomap_begin` 在 ftrace 里显示为 `erofs_iomap_begin.constprop.0`**。     
   按 `erofs_iomap_begin` 过滤有效，按全名 grep 会漏。

7. **QEMU 报 `Failed to get 'write' lock`**
   镜像还被上一次的 VM 或宿主机 mount 占着。先确认 `pgrep -c qemu-system` 和 `mount | grep erofs-rootfs` 都为 0。

8. **首行命令会被吞**
   自动化喂命令时先 `sleep 25`，第一行放注释当占位；最后补 `poweroff -f` 让 VM 自己关机。

9. **阶段 0 的计数是「全系统」的，只能定性**
   dd 窗口内 rootfs ext4（`/dev/vda`）的 jbd2/kworker 后台 IO 也会被记进
   `submit_bio`（fileio 实验里那 470 次全部来自 rootfs，与 EROFS 无关）。
   判断 EROFS 自己走没走块设备层，要看阶段 1 以 `__x64_sys_read` 为根的图：
   fileio 图内 `submit_bio` 为 0，bdev 图内 9 次。
   同理，`vfs_read=92` / `ksys_read=54` 也含其他进程的读，不是 dd 一家的。

10. **异步完成函数不进 syscall 图**
    `vfs_iocb_iter_read()` 返回 `-EIOCBQUEUED` 时，`erofs_fileio_ki_complete()`
    由镜像文件所在文件系统（这里是 9p/netfs）的完成上下文触发，不在 dd 的
    调用栈里——图内 0 次、阶段 0 全系统 62 次。想抓它得把根函数换成
    `erofs_fileio_ki_complete` 本身或去掉 `set_graph_function` 全量抓。

11. **图内计数也可能混入 rootfs 调页**
    `drop_caches` 把 dd 自己的代码页也驱逐了，read 路径上 ext4 会重新调页，
    在图里留下以 `ext4_*`/`iomap` 为前缀的帧和少量 `submit_bio`。
    区分办法是看父帧：EROFS 的 bio 一定挂在 `iomap_bio_submit_read` 之下。

## 6. 一键复现

```bash
# --- 宿主机：写脚本进镜像 ---
mount -o loop /home/linux/erofs/erofs-rootfs-ext4.img /mnt/rt
cat /home/linux/erofs/trace-graph/trace-read-fileio.sh > /mnt/rt/trace-read-fileio.sh
cat /home/linux/erofs/trace-graph/trace-read-bdev.sh   > /mnt/rt/trace-read-bdev.sh
chmod +x /mnt/rt/trace-read-*.sh
sync && umount /mnt/rt

# --- A: fileio ---
cd /home/linux/erofs/linux-stable
( sleep 25 ; echo '/trace-read-fileio.sh __x64_sys_read' ; \
  echo 'echo MARK_SCRIPT_DONE' ; echo 'poweroff -f' ) | \
timeout 280 qemu-system-x86_64 -m 8192 -smp 4 -nographic \
  -kernel arch/x86/boot/bzImage --enable-kvm \
  -initrd /home/linux/erofs/erofs-boot-initrd.img \
  -append "console=ttyS0 rdinit=/init" \
  -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
  -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
  -monitor none -no-reboot > /home/linux/erofs/trace-graph/trace-read-fileio-raw-74.log 2>&1

# --- B: bdev（多一块 -drive）---
( sleep 25 ; echo '/trace-read-bdev.sh __x64_sys_read' ; \
  echo 'echo MARK_SCRIPT_DONE' ; echo 'poweroff -f' ) | \
timeout 280 qemu-system-x86_64 -m 8192 -smp 4 -nographic \
  -kernel arch/x86/boot/bzImage --enable-kvm \
  -initrd /home/linux/erofs/erofs-boot-initrd.img \
  -append "console=ttyS0 rdinit=/init" \
  -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
  -drive file=/home/linux/erofs/img-stable/test/images/plain.erofs,format=raw,if=virtio \
  -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
  -monitor none -no-reboot > /home/linux/erofs/trace-graph/trace-read-bdev-raw-74.log 2>&1

# --- 提图 ---
cd /home/linux/erofs/trace-graph
awk '/@@@@@@ GRAPH BEGIN/,/@@@@@@ GRAPH END/' trace-read-fileio-raw-74.log \
  | grep -v '^+ ' | tail -n +2 > graph-fileio-74.txt
awk '/@@@@@@ GRAPH BEGIN/,/@@@@@@ GRAPH END/' trace-read-bdev-raw-74.log \
  | grep -v '^+ ' | tail -n +2 > graph-bdev-74.txt
```
