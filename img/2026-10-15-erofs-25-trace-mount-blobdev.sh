#!/bin/sh
#
# 在【虚拟机内部】执行：ftrace function_graph 完整跟踪 erofs 多设备 mount 流程
#
# 目标：从 mount(2) 系统调用进入（__x64_sys_mount）到系统调用返回，
#       期间的全部函数调用、层级、耗时 —— 一行不漏。
#
# ★ 根函数必须是 __x64_sys_mount：
#   do_mount / ksys_mount / vfs_kern_mount 与调用方同 TU 被内联，
#   ftrace 运行时插桩进不去（实测 0 命中，见 multidev/README 的坑记录）。
#
# ★ 不设置任何 set_graph_notrace / set_ftrace_filter：
#   用户要求"不得遗漏任何函数"，这里给全量子树。
#   噪声控制只靠三条：单一根函数 + funcgraph-irqs=0（不进中断）+
#   事后按进程名过滤（只要 busybox mount 进程的记录）。

TD=/sys/kernel/tracing
OUT=/host/multidev
MAINDEV=/dev/vdb
BLOBDEV=/dev/vdc

set -x

# ── ① 补设备节点（switch root 后 /dev 不自动重建 virtio 节点）────
mdev -s 2>/dev/null
ls $MAINDEV >/dev/null 2>&1 || mknod $MAINDEV b 253 16
ls $BLOBDEV >/dev/null 2>&1 || mknod $BLOBDEV b 253 32
ls -la /dev/vd*

mkdir -p /mnt/md
cd $TD || exit 1

# ── ② ftrace 配置：function_graph + 单根 __x64_sys_mount ────────
echo 0 > tracing_on
echo > trace
echo > set_graph_function
echo > set_graph_notrace
echo > set_ftrace_filter
echo > set_ftrace_notrace
echo nop > current_tracer
echo 2048 > buffer_size_kb            # 4 vCPU × 2048KB，防溢出
echo function_graph > current_tracer
echo __x64_sys_mount > set_graph_function
echo 0 > options/funcgraph-irqs       # 关中断展开（中断不属于 mount 调用链）
echo 1 > options/funcgraph-proc       # 带进程名+PID，事后按进程过滤
echo 1 > options/funcgraph-tail       # 叶子带 } /* func */ 尾注
echo 1 > options/funcgraph-abstime    # 绝对时间戳

# ── ③ 正式抓取：tracing_on 只覆盖 mount 命令本身 ────────────────
echo 1 > tracing_on
mount -t erofs -o device=$BLOBDEV $MAINDEV /mnt/md
RC=$?
echo 0 > tracing_on

echo "@@@@@@ MOUNT_RC=$RC @@@@@@"
mount | grep -F /mnt/md
ls -la /mnt/md

# ── ④ 结果直写 9p 共享目录（不经过串口，防堵死）────────────────
cat trace > $OUT/graph-mount-full.log
LINES=$(wc -l < $OUT/graph-mount-full.log)
echo "@@@@@@ GRAPH_MOUNT_BEGIN lines=$LINES out=graph-mount-full.log @@@@@@"
grep -c "erofs_" $OUT/graph-mount-full.log
echo "@@@@@@ GRAPH_MOUNT_END @@@@@@"
