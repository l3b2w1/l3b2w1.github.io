#!/bin/sh
#
# 在【虚拟机内部】执行：挂载三个对照镜像，用 ftrace function_graph 抓读路径
#
# ★ 本次改动：三个 .erofs 已经打包进 ext4 rootfs（/images/），不再走额外的 virtio 盘。
#   挂载时源是普通文件，busybox 会自动分配 loop 设备。
#   三个镜像同时挂载需要 3 个 loop —— VM 里默认只有 loop0，要自己补节点。
#
#   /images/plain.erofs  普通压缩（对照）
#   /images/frag.erofs   all-fragments（数据都在 packed inode）
#   /images/ztail.erofs  ztailpacking（尾部内联进 inode）
#
# 用法（VM 内）： sh /host/fragment/trace-fragment.sh [根函数名]

FUNCTION=${1:-__x64_sys_read}
TD=/sys/kernel/tracing
OUT=/host/fragment

set -x

# ── ① 准备 loop 设备节点（主设备号 7）──────────────────────────
# 三个镜像要同时挂着，所以需要 loop0/1/2
for i in 0 1 2 3; do
	ls /dev/loop$i >/dev/null 2>&1 || mknod /dev/loop$i b 7 $i
done
ls -la /dev/loop*
ls -la /images/

# ── ② 挂载三个镜像 ────────────────────────────────────────────
mkdir -p /mnt/plain /mnt/frag /mnt/ztail
mount -t erofs /images/plain.erofs /mnt/plain ; echo "@@@@@@ MOUNT_plain=$? @@@@@@"
mount -t erofs /images/frag.erofs  /mnt/frag  ; echo "@@@@@@ MOUNT_frag=$? @@@@@@"
mount -t erofs /images/ztail.erofs /mnt/ztail ; echo "@@@@@@ MOUNT_ztail=$? @@@@@@"
mount | grep erofs
ls -la /mnt/frag

cd $TD || exit 1

# ── ③ ftrace 配置 ─────────────────────────────────────────────
setup_trace() {
	echo 0 > tracing_on
	echo > trace
	echo > set_graph_function
	echo > set_graph_notrace
	echo > set_ftrace_filter
	echo > set_ftrace_notrace

	echo nop > current_tracer
	echo 512 > buffer_size_kb
	echo function_graph > current_tracer
	echo "$FUNCTION" >> set_graph_function

	echo 0 > options/funcgraph-irqs
	echo 1 > options/funcgraph-proc
	echo 1 > options/funcgraph-tail
	echo 1 > options/funcgraph-abstime

	for f in mutex_lock mutex_unlock down_read up_read down_write up_write \
	         down_write_trylock schedule io_schedule schedule_timeout \
	         __wake_up finish_wait add_wait_queue remove_wait_queue \
	         rcu_note_context_switch ktime_get current_time timestamp_truncate \
	         touch_atime atime_needs_update generic_update_time file_update_time \
	         __fsnotify_parent fsnotify security_file_permission \
	         uart_write uart_start __uart_start redirected_tty_write \
	         uart_write_room uart_flush_chars ldsem_down_read ldsem_up_read \
	         process_echoes; do
		echo "$f" >> set_graph_notrace
	done
	echo "tty_*"   >> set_graph_notrace
	echo "n_tty_*" >> set_graph_notrace
}

# ── ④ 抓一次读：结果写 9p ─────────────────────────────────────
grab() {
	echo > trace
	echo 3 > /proc/sys/vm/drop_caches
	echo 1 > tracing_on
	dd if=$1 of=/dev/null bs=4096 ${3:+skip=$3} count=8 2>/dev/null
	echo 0 > tracing_on

	cat trace > $OUT/graph-$2.log
	LINES=$(wc -l < $OUT/graph-$2.log)
	echo "@@@@@@ GRAPH_BEGIN $2 file=$1 lines=$LINES out=graph-$2.log @@@@@@"
	echo "  erofs_bread           : $(grep -c erofs_bread $OUT/graph-$2.log)"
	echo "  z_erofs_scan_folio    : $(grep -c z_erofs_scan_folio $OUT/graph-$2.log)"
	echo "  decompressed_bvec     : $(grep -c z_erofs_do_decompressed_bvec $OUT/graph-$2.log)"
	echo "@@@@@@ GRAPH_END $2 @@@@@@"
}

setup_trace

grab /mnt/plain/text.bin A_PLAIN
grab /mnt/frag/rnd1.bin  B_FRAGMENT

# ztailpacking 的 inline 数据在尾部：读最后几块
TAILBLK=$(expr $(stat -c %s /mnt/ztail/small.bin) / 4096)
echo "@@@@@@ ztail small.bin blocks=$TAILBLK @@@@@@"
grab /mnt/ztail/small.bin C_ZTAILPACKING

echo "@@@@@@ SCRIPT_DONE @@@@@@"
