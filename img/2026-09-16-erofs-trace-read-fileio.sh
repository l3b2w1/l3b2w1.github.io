#!/bin/sh
#
# 跟踪 EROFS 的 read 流程，输出 function_graph 调用图
#
# 用法： /trace-read.sh [根函数名]
#        不传参数时默认 __x64_sys_read
#
# ★ 重要：根函数不能用 vfs_read / ksys_read / do_mount 这类"同 TU 被内联"的名字，
#   它们虽然在 /proc/kallsyms 里有符号，但 ftrace 插桩的独立函数体运行时不会进入，
#   实测 0 命中（do_mount 就是典型）。脚本开头的 PROBE 阶段会逐个验证。
#
set -x

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

# ================= 阶段 0：探测哪些函数真的能被 ftrace 抓到 =================
echo function > current_tracer
echo > trace
echo 3 > /proc/sys/vm/drop_caches
echo 1 > tracing_on
dd if=$MNT/big.bin of=/dev/null bs=4096 count=16 2>/dev/null
echo 0 > tracing_on
echo "@@@@@@ PROBE @@@@@@"
for f in __x64_sys_read vfs_read ksys_read new_sync_read erofs_file_read_iter filemap_read erofs_read_folio erofs_readahead erofs_iomap_begin erofs_map_blocks erofs_map_dev; do
	echo "PROBE_$f=$(grep -c "$f" trace)"
done
echo "@@@@@@ PROBE END @@@@@@"

# ================= 阶段 1：正式抓调用图 =================
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

# ---- 过滤无关函数（已剔除 x86 上不存在的 pl011_* / update_maxtrace / rcu_all_qs / arch_counter_read）----
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
