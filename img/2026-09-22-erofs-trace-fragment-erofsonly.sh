#!/bin/sh
#
# VM 内执行：只展开【EROFS 内部】调用图
#
# 与 trace-fragment.sh 的区别：
#   trace-fragment.sh      的 graph 根是 __x64_sys_read —— 会连 VFS/mm 一起展开，噪声大
#   本脚本                 把根设成 EROFS 自己的入口函数 —— 展开的就是 EROFS 内部
#
# 根函数（EROFS 入口）：
#   erofs_file_read_iter      读入口
#   z_erofs_readahead         压缩读入口
#   z_erofs_scan_folio        压缩读主循环（fragment / inline 的差异都在这里面）
#   z_erofs_map_blocks_iter   映射入口
#
# 结果同样写进 9p（不往串口 cat）。

TD=/sys/kernel/tracing
OUT=/host/fragment

set -x

ls /images/ >/dev/null 2>&1
for i in 0 1 2 3; do ls /dev/loop$i >/dev/null 2>&1 || mknod /dev/loop$i b 7 $i; done
mkdir -p /mnt/plain /mnt/frag /mnt/ztail
mount -t erofs /images/plain.erofs /mnt/plain 2>/dev/null
mount -t erofs /images/frag.erofs  /mnt/frag  2>/dev/null
mount -t erofs /images/ztail.erofs /mnt/ztail 2>/dev/null
mount | grep erofs

cd $TD || exit 1

echo 0 > tracing_on
echo > trace
echo > set_graph_function
echo > set_graph_notrace
echo > set_ftrace_filter
echo > set_ftrace_notrace

echo nop > current_tracer
echo 1024 > buffer_size_kb
echo function_graph > current_tracer

# ── 根函数：EROFS 自己的入口 ──
echo erofs_file_read_iter     >> set_graph_function
echo z_erofs_readahead        >> set_graph_function
echo z_erofs_scan_folio       >> set_graph_function
echo z_erofs_map_blocks_iter  >> set_graph_function

echo 0 > options/funcgraph-irqs
echo 1 > options/funcgraph-proc
echo 1 > options/funcgraph-tail
echo 1 > options/funcgraph-abstime

# ── 把不相干的都屏蔽掉（锁 / 调度 / 时间 / tty / RCU / 内存分配 / sg / 等待）──
for f in mutex_lock mutex_unlock _raw_spin_lock _raw_spin_unlock _raw_spin_lock_irq \
         _raw_spin_unlock_irq rwsem_down_read_failed down_read up_read down_write up_write \
         schedule schedule_timeout io_schedule wait_for_completion wait_for_completion_io \
         __wake_up finish_swait prepare_to_wait_event add_wait_queue remove_wait_queue \
         rcu_all_qs rcu_note_context_switch __rcu_read_lock __rcu_read_unlock \
         ktime_get ktime_get_coarse_real_ts64 ktime_get_real_seconds current_time \
         timestamp_truncate touch_atime atime_needs_update generic_update_time file_update_time \
         __fsnotify_parent fsnotify security_file_permission \
         uart_write uart_start __uart_start redirected_tty_write uart_write_room \
         uart_flush_chars ldsem_down_read ldsem_up_read process_echoes \
         preempt_count_add preempt_count_sub preempt_count_sub_var \
         folio_add_lru folio_alloc_noprof folio_mark_accessed folio_batch_move_lru \
         __mod_zone_page_state mod_node_page_state; do
	echo "$f" >> set_graph_notrace
done
echo "tty_*"   >> set_graph_notrace
echo "n_tty_*" >> set_graph_notrace

grab() {
	echo > trace
	echo 3 > /proc/sys/vm/drop_caches
	echo 1 > tracing_on
	dd if=$1 of=/dev/null bs=4096 count=8 2>/dev/null
	echo 0 > tracing_on
	cat trace > $OUT/raw-eo-$2.log
	echo "@@@@@@ EO_BEGIN $2 file=$1 lines=$(wc -l < $OUT/raw-eo-$2.log) @@@@@@"
	echo "@@@@@@ EO_END $2 @@@@@@"
}

grab /mnt/plain/text.bin A_PLAIN
grab /mnt/frag/rnd1.bin  B_FRAGMENT
grab /mnt/ztail/small.bin C_ZTAILPACKING

echo "@@@@@@ EO_SCRIPT_DONE @@@@@@"
