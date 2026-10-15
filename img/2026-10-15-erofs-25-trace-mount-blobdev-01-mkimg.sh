#!/bin/sh
# 01 · 用户态用 mkfs.erofs 制作【多设备】EROFS 镜像
#
#   主设备  main.erofs ：superblock / 元数据 / 可压缩文件的数据
#   额外设备 blob.img  ：不可压缩的 chunk-based 数据（--blobdev 指定）
#
# 关键：只有「压缩不划算」的 chunk 才会被放进额外设备。
#       所以测试数据必须包含真随机（不可压缩）内容，否则 blob.img 会是 0 字节。
#
# 用法： sh /sdd/erofs/multidev/01-mkimg.sh

set -e

W=/sdd/erofs/multidev
MKFS=/opt/erofs-utils/bin/mkfs.erofs
DUMP=/opt/erofs-utils/bin/dump.erofs

mkdir -p $W/src2
cd $W

# ── ① 造测试数据 ────────────────────────────────────────────────
# rnd4m.bin ：真随机，压不动 → chunk-based，落到 device 1（blob）
head -c 4194304 /dev/urandom > src2/rnd4m.bin
# text1m.bin：高度重复，压缩率极高 → 留在主设备 device 0
yes "repeatable payload for lz4" | head -c 1048576 > src2/text1m.bin

# ── ② 备好额外设备文件 ──────────────────────────────────────────
rm -f main.erofs blob.img
truncate -s 64M blob.img

# ── ③ 造多设备镜像 ──────────────────────────────────────────────
# --chunksize=65536 开启 chunk-based；--blobdev 指定额外设备
$MKFS -b4096 --chunksize=65536 -zlz4 --blobdev=$W/blob.img main.erofs src2

echo
echo "=================== 产物 ==================="
ls -la main.erofs blob.img

echo
echo "=================== 验证 1：incompat 特性 ==================="
$DUMP -s main.erofs | grep -i "incompatible"

echo
echo "=================== 验证 2：rnd4m.bin 的落点（应在 device 1）==================="
$DUMP --path=/rnd4m.bin -e main.erofs

echo
echo "=================== 验证 3：text1m.bin 的落点（应在主设备）==================="
$DUMP --path=/text1m.bin -e main.erofs

echo
echo "=================== 验证 4：带 --device 解析额外设备 ==================="
$DUMP --device=$W/blob.img -s main.erofs | head -20

echo
echo "[01-mkimg] 完成"
