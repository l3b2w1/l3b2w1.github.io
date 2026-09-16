#!/bin/sh
#
# 跟踪 EROFS 的 read 流程 —— 块设备（bdev）路径版
#
# 与 trace-read.sh 的区别：镜像通过 loop 设备挂载，
# 于是 erofs_is_fileio_mode() 为假，a_ops 选 erofs_aops，
# 走 erofs_readahead / erofs_iomap_begin / submit_bio 这一支。
#
# 用法： /trace-read-bdev.sh [根函数名]   默认 __x64_sys_read
#
set -x

FUNCTION=$1
IMG=/host/img-stable/test/images/plain.erofs
MNT=/mnt/bdev
DEV=/dev/vdb
TRACING_DIR=/sys/kernel/tracing

cd $TRACING_DIR || exit 1

# 1. 用真正的块设备挂载（保证走块设备路径）
#
# ⚠️ 不要用 loop：这台 VM 的 /ko 模块是给别的内核编的（virtio_blk/mbcache/jbd2/ext4
#    全部 "invalid module format"），loop 挂上去读回来不对，内核报
#    "cannot find valid erofs superblock"。
#    ⇒ 改为把 erofs 镜像作为第二块 virtio-blk 直接挂进来（/dev/vdb）。
mkdir -p $MNT
# rootfs 的 /init 只挂了 proc / sys / tracefs / 9p，没挂 /dev ⇒ 设备节点不存在
mount | grep -q " /dev " || mount -t devtmpfs devtmpfs /dev
ls -l $DEV 2>/dev/null || mknod $DEV b 254 16
ls -l $DEV
mount | grep -q "$MNT" || mount -t erofs $DEV $MNT
mount | grep -F "$MNT"

# 2. 停止追踪并清空
echo 0 > tracing_on
echo > trace
echo > set_graph_function
echo > set_graph_notrace
echo > set_ftrace_filter
echo > set_ftrace_notrace

# ============ 阶段 0：探测哪些函数真的能被 ftrace 抓到 ============
echo function > current_tracer
echo > trace
echo 3 > /proc/sys/vm/drop_caches
echo 1 > tracing_on
dd if=$MNT/big.bin of=/dev/null bs=4096 count=16 2>/dev/null
echo 0 > tracing_on
echo "@@@@@@ PROBE @@@@@@"
for f in __x64_sys_read vfs_read ksys_read new_sync_read erofs_file_read_iter filemap_read erofs_read_folio erofs_readahead erofs_iomap_begin iomap_readahead erofs_map_blocks erofs_map_dev submit_bio erofs_fileio_readahead; do
	echo "PROBE_$f=$(grep -c "$f" trace)"
done
echo "@@@@@@ PROBE END @@@@@@"

# ============ 阶段 1：正式抓调用图 ============
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

# ---- 过滤无关函数 ----
echo mutex_lock        >> set_graph_notrace
echo mutex_unlock      >> set_graph_notrace
echo down_read         >> set_graph_notrace
echo up_read           >> set_graph_notrace
echo down_write        >> set_graph_notrace
echo up_write          >> set_graph_notrace
echo down_write_trylock >> set_graph_notrace
echo schedule          >> set_graph_notrace
echo io_schedule       >> set_graph_notrace
echo schedule_timeout  >> set_graph_notrace
echo __wake_up         >> set_graph_notrace
echo finish_wait       >> set_graph_notrace
echo add_wait_queue    >> set_graph_notrace
echo remove_wait_queue >> set_graph_notrace
echo rcu_note_context_switch >> set_graph_notrace
echo ktime_get              >> set_graph_notrace
echo current_time           >> set_graph_notrace
echo timestamp_truncate     >> set_graph_notrace
echo touch_atime            >> set_graph_notrace
echo atime_needs_update     >> set_graph_notrace
echo generic_update_time    >> set_graph_notrace
echo file_update_time       >> set_graph_notrace
echo __fsnotify_parent >> set_graph_notrace
echo fsnotify          >> set_graph_notrace
echo security_file_permission >> set_graph_notrace
echo uart_write        >> set_graph_notrace
echo uart_start        >> set_graph_notrace
echo __uart_start      >> set_graph_notrace
echo redirected_tty_write >> set_graph_notrace
echo uart_write_room   >> set_graph_notrace
echo uart_flush_chars  >> set_graph_notrace
echo ldsem_down_read   >> set_graph_notrace
echo ldsem_up_read     >> set_graph_notrace
echo process_echoes    >> set_graph_notrace
echo "tty_*" >> set_graph_notrace
echo "n_tty_*" >> set_graph_notrace

# ---- 开抓 ----
echo > trace
echo 3 > /proc/sys/vm/drop_caches
echo 1 > tracing_on
dd if=$MNT/big.bin of=/dev/null bs=4096 count=16 2>/dev/null
echo 0 > tracing_on

echo "@@@@@@ GRAPH BEGIN @@@@@@"
cat trace
echo "@@@@@@ GRAPH END @@@@@@"
