---
layout:     post
title:      EROFS two blobdevs vm test
subtitle:   EROFS 双blobdev虚拟机测试
date:       2026-09-30
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# 双 blobdev 多设备测试：完整过程

> **本测试要回答的问题**
>
> `mkfs.erofs -b4096 --chunksize=65536 -zlz4 --blobdev=/dev/sdb1 --blobdev=/dev/sdc1 /dev/sda1 srcdir`
>
> 1. 每个设备最终装了什么类型的数据？由什么规则决定？
> 2. **两个 `--blobdev` 是不是真的都生效？**（核心疑点）
> 3. 挂载时 `device=` 该给几个？给错会怎样？
>

## 0. 测试策略

分三层取证，互相印证：

| 层次 | 手段 | 能证明什么 |
|---|---|---|
| 宿主机 | `du` 看 blob 实际占用 | 哪个 blob 被真写入（区分稀疏空洞 vs 真数据） |
| 宿主机 | `cmp` / `od` 比对内容 | blob 里装的是不是原始数据 |
| 虚拟机 | 三种 `mount` 组合 + 读文件 | 内核侧挂载与跨设备读的真实行为 |

## 1. 阶段零：环境清场（必须先做）

#### 1.1 检查残留 VM 进程 —— 本次实际踩到的坑

QEMU 对镜像文件加**写锁**，只要有残留 VM 占着 `erofs-rootfs-ext4.img`，新的 VM 就起不来：

```
qemu-system-x86_64: -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio:
Failed to get "write" lock
Is another process using the image [/home/linux/erofs/erofs-rootfs-ext4.img]?
```

排查与清理：

```bash
# 找出残留 qemu（etime 列能看到它跑了多久）
ps -eo pid,etime,cmd | grep -i qemu | grep -v grep

# 本次的实际情况：PID 2574176 已经跑了 07:06:29（7 小时），是个卡住的旧测试
# 清掉它
kill -9 2574176
sleep 2
ps -p 2574176 > /dev/null 2>&1 && echo "仍在" || echo "已清除"
```

#### 1.2 关键路径

```bash
W=/home/linux/erofs/multidev/twoblob    # 本次测试的工作目录
MKFS=/home/linux/erofs/erofs-utils/mkfs/mkfs.erofs       # mkfs.erofs 1.9.4
DUMP=/home/linux/erofs/erofs-utils/dump/dump.erofs       # dump.erofs 1.9.4
KDIR=/home/linux/erofs/linux-stable                      # 内核树（bzImage 在这里）
ROOTFS=/home/linux/erofs/erofs-rootfs-ext4.img           # VM 的根文件系统（ext4）
INITRD=/home/linux/erofs/erofs-boot-initrd.img           # initrd
```

## 2. 阶段一：宿主机造镜像

#### 2.1 造测试数据

**必须同时包含「能压」和「压不动」两类**，这一步是**测试成败的关键**。   
`--blobdev` 只装 chunk-based 数据，而一个文件只有在**压缩不划算**时才会走 chunk。   
所以源数据里必须有真随机内容，否则 blob 会是 0 字节，什么都测不出来。

```bash
W=/home/linux/erofs/multidev/twoblob
rm -rf $W; mkdir -p $W/src; cd $W

# 真随机 4M：压不动 → 压缩 fallback → chunk-based → 落到 blob
head -c 4194304 /dev/urandom > src/rnd4m.bin

# 高度重复 1M：压缩率极高 → 压缩成功 → 留在主设备
yes repeat | head -c 1048576 > src/text1m.bin
```

#### 2.2 准备两个 blob 文件

```bash
truncate -s 64M blobA.img
truncate -s 64M blobB.img
```

注意 `truncate` 创建的是**稀疏文件**：`ls` 看是 64M，但实际占用磁盘为 0。  
后面正是靠这个特性来区分「有没有被 mkfs 写入」。

#### 2.3 造镜像（故意给两个 --blobdev）

```bash
$MKFS -b4096 --chunksize=65536 -zlz4 \
    --blobdev=$W/blobA.img --blobdev=$W/blobB.img \
    main2.erofs src
```

- `-b4096`：块大小 4K
- `--chunksize=65536`：开启 chunk-based（64K 一块）
- `-zlz4`：压缩算法
- `--blobdev=`：**重点**——连续给两个，用来验证是否都生效
- `main2.erofs`：主镜像（输出）
- `src`：源目录

#### 2.4 宿主机验证：哪个 blob 真被写了

```bash
# 表观大小
ls -l blobA.img blobB.img main2.erofs

# 实际占用磁盘 —— 关键判据
du -h --apparent-size blobA.img blobB.img   # 表观
du -h blobA.img blobB.img                   # 实际占用
```

实测输出：

```
-rw-r--r-- 67108864  blobA.img     # 表观 64M
-rw-r--r--  4194304  blobB.img     # 表观 4M
-rw-r--r--    12288  main2.erofs   # 12K（元数据 + 压缩数据）

du:  blobA.img = 0        ← 完全没被写（还是稀疏空洞）
     blobB.img = 4.0M     ← 真写入了
```

再比对内容：

```bash
# blobB 是否等于原始随机数据
cmp -n 4194304 src/rnd4m.bin blobB.img && echo "相同：blobB 装的是真数据"

# blobA 前 4M 的非零字节数（0 = 全是空洞）
head -c 4194304 blobA.img | tr -d "\000" | wc -c

# 前 16 字节对比
head -c 16 src/rnd4m.bin | od -An -tx1   # 1b a2 4f b6 81 4f 64 d5 ...
head -c 16 blobB.img     | od -An -tx1   # 1b a2 4f b6 81 4f 64 d5 ...  ← 一致
head -c 16 blobA.img     | od -An -tx1   # 00 00 00 00 00 00 00 00 ...  ← 全 0
```

⇒ **结论 1：两个 `--blobdev` 只有最后一个（blobB）生效。**

## 3. 阶段二：起 QEMU 虚拟机

#### 3.1 盘位规划（4 块盘）

| 盘 | 内容 |
|---|---|
| `vda` | rootfs（ext4，`erofs-rootfs-ext4.img`） |
| `vdb` | 主镜像 `main2.erofs` |
| `vdc` | blobA（`blobA.img`，空的） |
| `vdd` | blobB（`blobB.img`，真数据） |

#### 3.2 完整 QEMU 命令

```bash
cd /home/linux/erofs/linux-stable

QEMU_CMD="qemu-system-x86_64 -m 8192 -smp 4 -nographic \
 -kernel arch/x86/boot/bzImage --enable-kvm \
 -initrd /home/linux/erofs/erofs-boot-initrd.img \
 -append \"console=ttyS0 rdinit=/init\" \
 -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
 -drive file=$W/main2.erofs,format=raw,if=virtio \
 -drive file=$W/blobA.img,format=raw,if=virtio \
 -drive file=$W/blobB.img,format=raw,if=virtio \
 -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
 -monitor none -no-reboot"
```

#### 3.3 脚本方式起虚机

用 `/usr/bin/script` 造一个 pty，先等 VM 里的 shell 起来，再把命令文件一次性喂进去：

```bash
{ sleep 12; cat $W/vm-cmds-twoblob.txt; } \
  | timeout 300 /usr/bin/script -q -c "$QEMU_CMD" /dev/null > $W/vm-twoblob.log 2>&1
```

`02-run-twoblob.sh`脚本完整内容如下:

```
#!/bin/sh
W=/home/linux/erofs/multidev/twoblob
KDIR=/home/linux/erofs/linux-stable
CMDS=$W/vm-cmds-twoblob.txt
LOG=$W/vm-twoblob.log
BOOT_WAIT=12
TIMEOUT=300
cd $KDIR || exit 1
QEMU_CMD="qemu-system-x86_64 -m 8192 -smp 4 -nographic \
 -kernel arch/x86/boot/bzImage --enable-kvm \
 -initrd /home/linux/erofs/erofs-boot-initrd.img \
 -append \x27console=ttyS0 rdinit=/init\x27 \
 -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
 -drive file=$W/main2.erofs,format=raw,if=virtio \
 -drive file=$W/blobA.img,format=raw,if=virtio \
 -drive file=$W/blobB.img,format=raw,if=virtio \
 -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
 -monitor none -no-reboot"
echo "--- QEMU_CMD ---"
echo "$QEMU_CMD"
{ sleep $BOOT_WAIT; cat $CMDS; } | timeout $TIMEOUT /usr/bin/script -q -c "$QEMU_CMD" /dev/null > $LOG 2>&1
echo "qemu_exit=$?"
echo "=== 关键输出 ==="
grep -a "TEST._START\|MOUNT_RC\|erofs (device\|ALL_DONE\|rnd4m\|text1m" $LOG | sed "s/\r//g" | head -40
echo "=== 日志行数: $(wc -l < $LOG) ==="
```

- **为什么不需要交互式同步**：busybox sh 会**按顺序**执行，一条跑完才读下一条，
  所以不用等提示符、不用加完成标记。
- 只需在喂之前 `sleep 12` 等 VM 内的 shell 起来。
- 命令文件**最后一条放 `poweroff -f`**，VM 主动关机 → QEMU 退出 → `script` 才结束。
- 宿主机侧用 `timeout 300` 兜底防挂死（124 = 超时）。

---

## 4. 阶段三：VM 内测试（命令文件全文）

文件 `vm-cmds-twoblob.txt`：

```sh
mdev -s
ls /dev/vdb > /dev/null 2>&1 || mknod /dev/vdb b 253 16
ls /dev/vdc > /dev/null 2>&1 || mknod /dev/vdc b 253 32
ls /dev/vdd > /dev/null 2>&1 || mknod /dev/vdd b 253 48
mkdir -p /mnt/md

echo @@@@@@ TEST1_START device=vdd blobB @@@@@@
mount -t erofs -o device=/dev/vdd /dev/vdb /mnt/md
echo @@@@@@ TEST1_MOUNT_RC=$? @@@@@@
ls -l /mnt/md
cat /mnt/md/rnd4m.bin | wc -c
umount /mnt/md

echo @@@@@@ TEST2_START device=vdc,vdd 两个 @@@@@@
mount -t erofs -o device=/dev/vdc,device=/dev/vdd /dev/vdb /mnt/md
echo @@@@@@ TEST2_MOUNT_RC=$? @@@@@@

echo @@@@@@ TEST3_START device=vdc blobA @@@@@@
mount -t erofs -o device=/dev/vdc /dev/vdb /mnt/md
echo @@@@@@ TEST3_MOUNT_RC=$? @@@@@@
cat /mnt/md/rnd4m.bin | wc -c

echo @@@@@@ ALL_DONE @@@@@@
poweroff -f
```

要点解释：

- `mdev -s`：switch root 后 `/dev` 没重建，`vdb/vdc/vdd` 要补；主设备号 253，次设备号按 16 递增（16/32/48）。
- 三个测试分别对应：**正确 blob**、**给两个 device**、**指向空 blob**。
- `@@@@@@` 包裹标记，方便宿主机 `grep` 抽取结果。


## 5. 结果

```
TEST1_START device=vdd blobB
[   11.627565] erofs (device vdb): mounted with root inode @ nid 40.
TEST1_MOUNT_RC=0
-rw-r--r-- 4194304 rnd4m.bin
-rw-r--r-- 1048576 text1m.bin
4194304                                    ← cat 读出的字节数

TEST2_START device=vdc,vdd 两个
[   11.670282] erofs (device vdb): extra devices don't match (ondisk 1, given 2)
TEST2_MOUNT_RC=255

TEST3_START device=vdc blobA
[   11.676053] erofs (device vdb): mounted with root inode @ nid 40.
TEST3_MOUNT_RC=0
4194304                                    ← 读出的字节数"正确"，但内容全是 0
ALL_DONE
```

宿主机侧抓取结果的命令：

```bash
grep -a "TEST._START\|MOUNT_RC\|erofs (device\|ALL_DONE\|rnd4m\|text1m\|mounted" \
    $W/vm-twoblob.log | sed "s/\r//g" | head -30
```

[vm-twoblob.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-30-erofs-40-vm-twoblob.log)

## 6. 结论

#### 结论 1：两个 `--blobdev` 只有最后一个生效

源码依据：

- `mkfs/main.c:1280` → `cfg.c_blobdev_path = optarg`：**单变量直接赋值**，不是追加，多次指定会覆盖。
- `lib/blobchunk.c:32` → `static int blobfile = -1`：只维护**一个** blob 文件描述符。
- `lib/blobchunk.c:496` → 有 extra_devices 时 `device_id = 1`：**固定为 1**。

实测依据：`blobA` 实际占用 0（未写），`blobB` 占用 4M 且内容与原始数据一致。

#### 结论 2：镜像里 `extra_devices = 1`

`struct erofs_super_block` 的 `extra_devices`（`__le16`）在结构内偏移 86–87，
即镜像 offset `1024 + 86 = 1110`。实测该处为 `01 00` → **1**。
所以挂载时必须只给**一个** `device=`；给两个会被内核拒绝（TEST2，RC=255）。

#### 结论 3：数据分流规则是「压缩优先，退回才 chunk」

```
每个文件
├─ 有压缩算法 且 erofs_file_is_compressible()      ← lib/inode.c:2385
│   ├─ 是 → erofs_write_compressed_file()
│   │        ├─ 成功 → COMPRESSED_*   数据（pcluster）留主设备
│   │        └─ EROFS_RETVAL_FALLBACK（压了没收益）→ 退回
│   └─ 否 → 退回
└─ erofs_write_unencoded_file()                     ← lib/inode.c:707
     ├─ cfg.c_chunkbits 已设（给了 --chunksize）→ erofs_blob_write_chunked_file()
     │                                       → CHUNK_BASED，数据写 blob
     └─ 否则 → FLAT_* / FLAT_INLINE，数据留主设备
```

实测：`text1m.bin`（重复内容）→ Layout 3（压缩，主设备）；
`rnd4m.bin`（随机）→ Layout 4（chunk-based，进 blob）。

各设备最终装了什么：

| 设备 | 内容 |
|---|---|
| 主设备 | superblock、inode 区、dirent、xattr（**所有元数据**）+ 压缩成功的 pcluster + flat 数据块 |
| blob | **只有** chunk-based 文件的 chunk 数据 |

#### 结论 4（最危险）：指向空 blob 是**静默数据损坏**

TEST3 挂载**不报错**（RC=0）、`ls` 文件大小**正确**、`cat | wc -c` 也**正确**（4194304），
但读出来的内容**全是 0** —— 因为 blobA 是稀疏空洞。

⇒ 不报错、大小对、看似正常，**只有内容是错的**。这种错在系统里能潜伏很久。
务必确认 `device=` 指向 mkfs 真正写入的那个 blob（给两个 `--blobdev` 时是**最后一个**）。

## 7. 正确的命令（基于以上结论）

```bash
# 造镜像：只给一个 blobdev
mkfs.erofs -b4096 --chunksize=65536 -zlz4 \
    --blobdev=/dev/sdb1 \
    /dev/sda1 /path/to/srcdir

# 挂载：只给一个 device=
mount -t erofs -o device=/dev/sdb1 /dev/sda1 /mnt/erofs
```

## 8. 本次踩到的坑汇总

1. **残留 qemu 进程占 rootfs 写锁** → `Failed to get "write" lock`。
   跑之前先 `ps -eo pid,etime,cmd | grep qemu` 检查并清理。
2. **`-append` 的值漏引号** → QEMU 把 `rdinit=/init` 当文件路径。必须引号包裹。
3. **ssh 单引号 + heredoc 写远端脚本不稳** → 出现「写成功但执行时说找不到」。
   写脚本要单独调用验证，或干脆内联命令不落盘。
4. **源数据必须含不可压缩内容** → 否则 blob 为 0 字节，测不出分流行为。

## 9. 产物清单（`/home/linux/erofs/multidev/twoblob/`）

| 文件 | 说明 |
|---|---|
| `src/rnd4m.bin` | 源数据：随机 4M（压不动 → 进 blob） |
| `src/text1m.bin` | 源数据：重复 1M（压缩 → 留主设备） |
| `blobA.img` | blob 1（**实际未被写入**，全空洞） |
| `blobB.img` | blob 2（真写入 4M） |
| `main2.erofs` | 主镜像（12K，元数据 + 压缩数据） |
| `vm-cmds-twoblob.txt` | VM 内测试命令序列 |
| `vm-twoblob.log` | VM 全部输出（502 行） |
| `02-run-twoblob.sh` | 起 VM 的脚本（内联 QEMU 命令） |


## 参考
[erofs-utils](https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git)
[linux-stable (93f51579e7df)](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git)  
