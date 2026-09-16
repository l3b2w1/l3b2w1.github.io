---
layout:     post
title:      EROFS trace read funcgraph
subtitle:   EROFS 跟踪读调用路径
date:       2026-09-16
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# EROFS read 流程追踪 —— 全部命令 + 提炼出的读路径栈

内容分两部分，两者除「镜像怎么挂」之外，追踪手法完全一致：

- **实验 A** — fileio（文件后端）read 路径
- **实验 B** — bdev（块设备）read 路径

## 0. 环境 / 前提

| 项 | 值 |
|---|---|
| 宿主机内核 | `5.10.0-136.12.0.86.4.nos1.x86_64`（ftrace 全开） |
| VM 内核 | `/home/linux/erofs/linux-stable`，`v7.3-rc3-60-g587858367581`<br>`CONFIG_FUNCTION_TRACER` / `FUNCTION_GRAPH_TRACER` / `DYNAMIC_FTRACE` 均为 `y` |
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
( sleep 25 ; cat /home/linux/erofs/trace-graph/vm-run-read.txt ) | \
  timeout 280 qemu-system-x86_64 ... > /home/linux/erofs/trace-graph/trace-read-fileio-raw.log 2>&1
```

> `sleep 25` 是等 VM 起来，否则第一行命令会被吞掉。

#### 2.2 VM 内命令

文件 `/home/linux/erofs/trace-graph/vm-run-read.txt`：

```sh
# 占位行
/trace-read-fileio.sh __x64_sys_read
echo MARK_SCRIPT_DONE
```

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

#### 2.3 脚本全文（`/trace-read-fileio.sh`）

![trace-read-fileio.sh](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-16-erofs-trace-read-fileio.sh)

完整内容见同目录 `trace-read-fileio.sh`，核心片段：

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
echo function > current_tracer
echo > trace
echo 3 > /proc/sys/vm/drop_caches
echo 1 > tracing_on
dd if=$MNT/big.bin of=/dev/null bs=4096 count=16 2>/dev/null
echo 0 > tracing_on
echo "@@@@@@ PROBE @@@@@@"
for f in __x64_sys_read vfs_read ksys_read new_sync_read erofs_file_read_iter \
         filemap_read erofs_read_folio erofs_readahead erofs_iomap_begin \
         erofs_map_blocks erofs_map_dev; do
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

# 过滤无关函数（约 35 行 echo ... >> set_graph_notrace，见脚本原文）

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

#### 2.4 PROBE 结果（实测）

```
PROBE___x64_sys_read=18
PROBE_vfs_read=92
PROBE_ksys_read=54
PROBE_new_sync_read=0            ← 同 TU 被内联，抓不到
PROBE_erofs_file_read_iter=16    ← dd bs=4096 count=16 ⇒ 正好 16 次 read()
PROBE_filemap_read=103
PROBE_erofs_read_folio=0         ← 走 fileio，不走这条
PROBE_erofs_readahead=0          ← 同上
PROBE_erofs_iomap_begin=0        ← 同上
PROBE_erofs_map_blocks=7
PROBE_erofs_map_dev=2
```

#### 2.5 提炼出的读路径栈（fileio）

[trace graph fileio full data](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-16-erofs-trace-graph-fileio.txt)

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
                      erofs_fileio_readahead() {        ★ fs/erofs/fileio.c
                        erofs_real_inode();             ← ishare 叠加点
                        erofs_fileio_scan_folio() {     ← 每个 folio 一段段处理
                          erofs_onlinefolio_init();
                          erofs_map_blocks();           ← m_pa / m_llen / m_deviceid
                          erofs_map_dev();              ← 解析出 m_dif->file（镜像文件）
                          erofs_fileio_rq_alloc() {     ← refcount 置 2
                            bio_init();
                          }
                          bio_add_folio() { bio_add_page() { __bio_add_page(); } }
                          erofs_onlinefolio_split();
                          erofs_onlinefolio_end();
                        }                               ← 重复 N 次（实测 25 次）
                        erofs_fileio_rq_submit() {      ★ 最后一公里
                          vfs_iocb_iter_read() {        ← 不经过块设备层
                            rw_verify_area();
                            v9fs_file_read_iter() {     ← 镜像文件在 9p 共享上
                              netfs_unbuffered_read_iter() {
                                netfs_start_io_direct();
                                netfs_unbuffered_read_iter_locked() { ... }
```

**一句话**：整条链上没有 `submit_bio`，没有块设备层；最后的 `vfs_iocb_iter_read()` 直接把「镜像文件」当普通文件读。  
这正是 09 专题 §六 的结论。

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

文件 `/home/linux/erofs/trace-graph/vm-run-bdev.txt`：

```sh
# 占位行
/trace-read-bdev.sh __x64_sys_read
echo MARK_SCRIPT_DONE
```

等价的手工版：

```sh
cd /sys/kernel/tracing
mkdir -p /mnt/bdev
mount -t devtmpfs devtmpfs /dev            # ★ /init 没挂 /dev，必须补
ls -l /dev/vdb || mknod /dev/vdb b 254 16  # 兜底建节点（实测主设备号为 253）
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

#### 3.3 脚本全文（`/trace-read-bdev.sh`）

![trace-read-fileio.sh](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-16-erofs-trace-read-bdev.sh)

与 fileio 版唯一差别在第 1 段（挂载方式）和 PROBE 列表，其余完全相同：

```sh
FUNCTION=$1
IMG=/host/img-stable/test/images/plain.erofs
MNT=/mnt/bdev
DEV=/dev/vdb
TRACING_DIR=/sys/kernel/tracing

cd $TRACING_DIR || exit 1

# 1. 用真正的块设备挂载（保证走块设备路径）
mkdir -p $MNT
mount | grep -q " /dev " || mount -t devtmpfs devtmpfs /dev
ls -l $DEV 2>/dev/null || mknod $DEV b 254 16
ls -l $DEV
mount | grep -q "$MNT" || mount -t erofs $DEV $MNT
mount | grep -F "$MNT"

# 2~4 段同 fileio 版（PROBE 列表额外包含 iomap_readahead / submit_bio /
#    erofs_fileio_readahead，完整内容见同目录 trace-read-bdev.sh）
```

#### 3.4 PROBE 结果（实测）

```
PROBE___x64_sys_read=18
PROBE_vfs_read=92
PROBE_ksys_read=54
PROBE_new_sync_read=0
PROBE_erofs_file_read_iter=16
PROBE_filemap_read=104
PROBE_erofs_read_folio=3          ★（fileio 版是 0）
PROBE_erofs_readahead=9           ★（fileio 版是 0）
PROBE_erofs_iomap_begin=23        ★（fileio 版是 0）
PROBE_iomap_readahead=42          ★（fileio 版是 0）
PROBE_erofs_map_blocks=7
PROBE_erofs_map_dev=5
PROBE_submit_bio=473              ★（fileio 版是 0）
PROBE_erofs_fileio_readahead=0    ★（fileio 版是 3）
```

#### 3.5 提炼出的读路径栈（bdev）

![trace graph bdev full data](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-16-erofs-trace-graph-bdev.txt)

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
                      erofs_readahead() {            ★ fs/erofs/data.c
                        erofs_real_inode();             （fileio 时是 erofs_fileio_readahead）
                        iomap_readahead() {          ← 内核通用 iomap 框架
                          iomap_iter() {
                            erofs_iomap_next() {
                              erofs_iomap_begin.constprop.0() {   ★ 分叉点
                                erofs_map_blocks();   ← m_pa / m_deviceid
                                erofs_map_dev();      ← 解析出 iomap->bdev
                              }
                            }
                          }
                          iomap_read_folio_iter() {
                            ifs_alloc.isra.0();
                            iomap_adjust_read_range();
                            iomap_bio_read_folio_range() {
                              bio_alloc_bioset();     ← 构造 bio
                              bio_add_folio_nofail(); ← 把目标页挂进 bio
                            }
                          }
                          iomap_bio_submit_read() {
                            submit_bio() {           ★ 进入块设备层
                              blkcg_set_ioprio();
                              submit_bio_noacct() {
                                submit_bio_noacct_nocheck() {
                                  blk_cgroup_bio_start();
                                  __submit_bio() {
                                    blk_mq_submit_bio() {
                                      bio_split_rw();
                                      blk_attempt_plug_merge();
                                      blk_mq_sched_bio_merge();
                                      __blk_mq_alloc_requests() { blk_mq_get_tag(); }
                                      ...
                                      virtio_queue_rqs()      ← 真正下发给 virtio-blk
```

**一句话**：`erofs_map_dev()` 填 `iomap->bdev`，之后由 iomap 框架 `submit_bio()`，再经 blk-mq → virtio-blk 下发。整条链上不出现 `vfs_iocb_iter_read()`。

## 4. 两条路对比（同一份 dd 命令，只有挂载方式不同）

| | fileio 挂载 | bdev 挂载 |
|---|---|---|
| 挂载命令 | `mount.erofs IMG /mnt/plain` | `mount -t erofs /dev/vdb /mnt/bdev` |
| `erofs_is_fileio_mode()` | 真（`dif0.file` 非空） | 假 |
| 选中的 `a_ops` | `erofs_fileio_aops` | `erofs_aops` |
| `.readahead` | `erofs_fileio_readahead` | `erofs_readahead` |
| 地址翻译 | `erofs_map_blocks/dev` 共用 | 同为 `erofs_map_blocks/dev` 共用 |
| 分叉点 | `erofs_fileio_rq_submit` | `erofs_iomap_begin` |
| 最后一步 | `vfs_iocb_iter_read()` | `submit_bio()` |
| 经过块设备层 | 否 | 是 |
| PROBE: `erofs_readahead` | 0 | 9 |
| PROBE: `erofs_fileio_readahead` | 3 | 0 |
| PROBE: `submit_bio` | 0 | 473 |
| read 系统调用 | 16 | 16 |
| 图行数 | 6065 | 2954 |

⇒ 挂载源是「文件」还是「块设备」决定 `erofs_get_aops()` 选哪套 `a_ops`，两条路互斥。见 09 专题 §3.2。

## 5. 注意事项

1. **根函数不能选「被内联」的函数**
   `do_mount`、`new_sync_read`、`do_new_mount` 都是 0 命中：  
   它们在 `/proc/kallsyms` 和 `System.map` 里都有符号，但 GCC 已把它们内联进调用者，ftrace 插桩的那份独立函数体运行时不会进入。  
   syscall 包装（`__x64_sys_*`）通常安全。脚本里的 PROBE 阶段就是用来逐个验证的。

2. **必须先 `drop_caches`**
   探测阶段读过一遍后页缓存就热了，第二次读只剩 236 行，`erofs_file_read_iter` 只花 4.3 µs。  
   加 `echo 3 > /proc/sys/vm/drop_caches` 后图从 236 行涨到 6068 行。

3. **`buffer_size_kb` 要放大（8192）**
   默认缓冲会被刷屏的读冲掉。

4. **`set_graph_function` 一旦非空，function_graph 只记录以该函数为根的图**

5. **`/dev/vdb` 默认不存在**
   rootfs 的 `/init` 只挂了 proc / sys / tracefs / 9p，没挂 `/dev`。脚本里补 `mount -t devtmpfs devtmpfs /dev`，再兜底 `mknod`。

6. **`erofs_iomap_begin` 在 ftrace 里显示为 `erofs_iomap_begin.constprop.0`**。     
  按 `erofs_iomap_begin` 过滤有效，按全名 grep 会漏。

7. **QEMU 报 `Failed to get 'write' lock`**
   镜像还被上一次的 VM 或宿主机 mount 占着。先确认 `pgrep -c qemu-system` 和 `mount | grep erofs-rootfs` 都为 0。

8. **首行命令会被吞**
   自动化喂命令时先 `sleep 25`，第一行放注释当占位。

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
( sleep 25 ; echo '/trace-read-fileio.sh __x64_sys_read' ) | \
timeout 280 qemu-system-x86_64 -m 8192 -smp 4 -nographic \
  -kernel arch/x86/boot/bzImage --enable-kvm \
  -initrd /home/linux/erofs/erofs-boot-initrd.img \
  -append "console=ttyS0 rdinit=/init" \
  -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
  -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
  -monitor none -no-reboot > /home/linux/erofs/trace-graph/trace-read-fileio-raw.log 2>&1

# --- B: bdev（多一块 -drive）---
( sleep 25 ; echo '/trace-read-bdev.sh __x64_sys_read' ) | \
timeout 280 qemu-system-x86_64 -m 8192 -smp 4 -nographic \
  -kernel arch/x86/boot/bzImage --enable-kvm \
  -initrd /home/linux/erofs/erofs-boot-initrd.img \
  -append "console=ttyS0 rdinit=/init" \
  -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
  -drive file=/home/linux/erofs/img-stable/test/images/plain.erofs,format=raw,if=virtio \
  -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
  -monitor none -no-reboot > /home/linux/erofs/trace-graph/trace-read-bdev-raw.log 2>&1

# --- 提图 ---
awk '/@@@@@@ GRAPH BEGIN/,/@@@@@@ GRAPH END/' trace-read-fileio-raw.log \
  | grep -v '^+ ' | tail -n +2 > graph-fileio.txt
awk '/@@@@@@ GRAPH BEGIN/,/@@@@@@ GRAPH END/' trace-read-bdev-raw.log \
  | grep -v '^+ ' | tail -n +2 > graph-bdev.txt
```
