#!/bin/sh
#
# VM 内执行：A/B/C/D 四项测试、共九段，全部只用【两个镜像】
#
#   /images/plain.erofs   不开 dedupe（A 段 + D 段的 shared.bin）
#   /images/dedupe.erofs  开 -Ededupe （B/C 段 + D 段的 shared.bin）
#
# 挂载分三个阶段（每个镜像同时只挂一次 —— 同一文件挂两次会撞 loop）：
#   阶段 1  普通挂载            → A / B / C1 / C2 / C3
#   阶段 2  同 domain + ishare  → D1 / D2
#   阶段 3  不同 domain + ishare → D3 / D4
#
# 结果写 9p（不往串口 cat）。

TD=/sys/kernel/tracing
OUT=/host/dedupe

set -x

mkdir -p /host
mount -t 9p -o trans=virtio,version=9p2000.L host /host
for i in 0 1 2 3; do ls /dev/loop$i >/dev/null 2>&1 || mknod /dev/loop$i b 7 $i; done
mkdir -p /mnt/plain /mnt/dedupe

# ══════════ 阶段 1：普通挂载 → A / B / C ══════════
mount -t erofs /images/plain.erofs  /mnt/plain  ; echo "@@@@@@ MOUNT_plain=$? @@@@@@"
mount -t erofs /images/dedupe.erofs /mnt/dedupe ; echo "@@@@@@ MOUNT_dedupe=$? @@@@@@"
mount | grep erofs
ls -la /mnt/dedupe

# 正确性校验：dedupe 镜像读出来的内容必须和源文件一致
cut -d" " -f1 /images/src.md5 > /tmp/want
md5sum /mnt/dedupe/a.bin /mnt/dedupe/b.bin /mnt/dedupe/c.bin | cut -d" " -f1 > /tmp/got
if diff -q /tmp/want /tmp/got >/dev/null; then
	echo "@@@@@@ MD5_dedupe=OK @@@@@@"
else
	echo "@@@@@@ MD5_dedupe=FAIL @@@@@@"
fi

cd $TD || exit 1
echo 0 > tracing_on
echo > trace
echo > set_graph_function
echo > set_graph_notrace
echo > set_ftrace_filter
echo nop > current_tracer
echo 512 > buffer_size_kb
echo function_graph > current_tracer
echo __x64_sys_read >> set_graph_function
echo 0 > options/funcgraph-irqs
echo 1 > options/funcgraph-abstime
for f in mutex_lock mutex_unlock down_read up_read down_write up_write \
         down_write_trylock schedule schedule_timeout io_schedule \
         __wake_up finish_wait add_wait_queue remove_wait_queue \
         rcu_all_qs rcu_note_context_switch __rcu_read_lock __rcu_read_unlock \
         ktime_get ktime_get_coarse_real_ts64 current_time timestamp_truncate \
         touch_atime atime_needs_update generic_update_time file_update_time \
         __fsnotify_parent fsnotify security_file_permission \
         uart_write uart_start __uart_start redirected_tty_write \
         uart_write_room uart_flush_chars ldsem_down_read ldsem_up_read \
         process_echoes; do
	echo "$f" >> set_graph_notrace
done
echo "tty_*"   >> set_graph_notrace
echo "n_tty_*" >> set_graph_notrace

# grab <文件> <标记> <是否drop:1/0> [预读文件]
grab() {
	[ "$3" = 1 ] && echo 3 > /proc/sys/vm/drop_caches
	if [ -n "$4" ]; then dd if=$4 of=/dev/null bs=4096 count=8 2>/dev/null; fi
	echo > trace
	echo 1 > tracing_on
	dd if=$1 of=/dev/null bs=4096 count=8 2>/dev/null
	echo 0 > tracing_on
	cat trace > $OUT/graph-$2.log
	echo "@@@@@@ GRAPH_BEGIN $2 file=$1 lines=$(wc -l < $OUT/graph-$2.log) @@@@@@"
	echo "@@@@@@ GRAPH_END $2 @@@@@@"
}

grab /mnt/plain/b.bin   A_PLAIN            1
grab /mnt/dedupe/b.bin  B_DEDUPE           1
grab /mnt/dedupe/a.bin  C1_READ_A          1
grab /mnt/dedupe/b.bin  C2_READ_B_AFTER_A  0
grab /mnt/dedupe/b.bin  C3_SAME_FILE       0

umount /mnt/plain; umount /mnt/dedupe
echo "@@@@@@ UMOUNT_STAGE1_DONE @@@@@@"

# ══════════ 阶段 2：同 domain + ishare → D1 / D2 ══════════
mount -t erofs -o domain_id=demo,inode_share /images/plain.erofs  /mnt/plain  ; echo "@@@@@@ MOUNT_plain_ishare=$? @@@@@@"
mount -t erofs -o domain_id=demo,inode_share /images/dedupe.erofs /mnt/dedupe ; echo "@@@@@@ MOUNT_dedupe_ishare=$? @@@@@@"
grab /mnt/plain/shared.bin  D1_ISHARE_A 1
grab /mnt/dedupe/shared.bin D2_ISHARE_B 0
umount /mnt/plain; umount /mnt/dedupe
echo "@@@@@@ UMOUNT_STAGE2_DONE @@@@@@"

# ══════════ 阶段 3：不同 domain → D3 / D4 ══════════
mount -t erofs -o domain_id=demoA,inode_share /images/plain.erofs  /mnt/plain  ; echo "@@@@@@ MOUNT_plain_domA=$? @@@@@@"
mount -t erofs -o domain_id=demoB,inode_share /images/dedupe.erofs /mnt/dedupe ; echo "@@@@@@ MOUNT_dedupe_domB=$? @@@@@@"
grab /mnt/plain/shared.bin  D3_DIFFDOMAIN_A 1
grab /mnt/dedupe/shared.bin D4_DIFFDOMAIN_B 0

echo "@@@@@@ SCRIPT_DONE @@@@@@"
