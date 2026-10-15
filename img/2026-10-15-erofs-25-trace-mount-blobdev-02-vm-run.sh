#!/bin/sh
# 02 · 宿主机侧：起 QEMU，把命令序列喂进 VM，全部输出落盘
#
# 用法： sh 02-vm-run.sh [命令文件] [输出日志]
#
# 思路（纯 shell，不用 python）：
#   一次性把命令喂给 VM 的 shell —— busybox sh 会【按顺序】执行，
#   一条跑完才读下一条，所以不需要交互式同步（不用等提示符、不用等标记）。
#   只需要在喂之前先 sleep 若干秒，等 VM 里的 shell 起来。
#
#   命令文件最后一条是 poweroff -f，VM 主动关机 → QEMU 退出 → script 结束。
#   若 VM 卡住，由宿主机的 timeout 兜底（VM 内 busybox 没有 timeout 命令）。

set -u

W=/sdd/erofs/multidev
KDIR=/sdd/erofs/linux-stable          # 内核源码树（bzImage 在这里）
CMDS=${1:-$W/vm-cmds.txt}
LOG=${2:-$W/trace-multidev.log}
BOOT_WAIT=${BOOT_WAIT:-10}            # 等 VM 内 shell 起来的秒数
TIMEOUT=${TIMEOUT:-420}               # 总超时（秒）

cd "$KDIR" || exit 1

QEMU_CMD="qemu-system-x86_64 -m 8192 -smp 4 -nographic \
 -kernel arch/x86/boot/bzImage --enable-kvm \
 -initrd /sdd/erofs/erofs-boot-initrd.img \
 -append 'console=ttyS0 rdinit=/init' \
 -drive file=/sdd/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
 -drive file=$W/main.erofs,format=raw,if=virtio \
 -drive file=$W/blob.img,format=raw,if=virtio \
 -virtfs local,path=/sdd/erofs,mount_tag=host,security_model=none,id=host0 \
 -monitor none -no-reboot"

echo "[vm-run] 内核树    : $KDIR"
echo "[vm-run] 命令文件  : $CMDS"
echo "[vm-run] 输出日志  : $LOG"
echo "[vm-run] 启动等待  : ${BOOT_WAIT}s   总超时: ${TIMEOUT}s"
echo

# 先等 VM 起来，再喂命令
{ sleep "$BOOT_WAIT"; cat "$CMDS"; } \
	| timeout "$TIMEOUT" /usr/bin/script -q -c "$QEMU_CMD" /dev/null > "$LOG" 2>&1
rc=$?

echo
echo "[vm-run] 退出码: $rc   (124 = 总超时, 说明 VM 没能正常关机)"
echo
echo "=== 关键标记 ==="
grep -a "MOUNT_RC\|GRAPH_BEGIN\|GRAPH_END\|SCRIPT_DONE\|ALL_DONE" "$LOG" \
	| sed 's/\r//g' | head -14
echo
echo "=== 日志: $LOG ($(wc -l < "$LOG") 行) ==="
exit $rc
