---
layout:     post
title:      QEMU two-stage startup scheme
subtitle:   QEMU 两段式启动方案
date:       2026-09-01
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - qemu
---

# QEMU 两段式启动方案：loader initrd + ext4 根文件系统

> 适用对象：需要在 QEMU guest 里以 **ext4 磁盘为根文件系统** 运行测试，而测试内核的 ext4/virtio-blk 都是模块（=m）的场景
>
> 环境：Code Server + QEMU +  6.6 内核
>
> 产物：`rootfs-ext4.img`（ext4 根）+ `boot-initrd.img`（loader initrd）
>
---

## 1. 为什么需要两段式

给 QEMU 挂个 ext4 磁盘然后 `root=/dev/vda` 直接启动。 自己所编译的内核做不到这一点，因为不想改配置。`.config`如下 ：

```
CONFIG_VIRTIO_BLK=m      # 磁盘驱动是模块
CONFIG_EXT4_FS=m         # 文件系统是模块
CONFIG_VIRTIO=y          # virtio 核心内建（这是幸运的）
CONFIG_VIRTIO_PCI=y      # virtio PCI 传输内建
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y  #
```

`root=/dev/vda` 直接启动会在 `prepare_namespace()` 阶段 panic：

```
/dev/root: Can't open blockdev
VFS: Cannot open root device "" or unknown-block(0,0): error -6
here are the available partitions:            ← 空：virtio_blk 未加载，看不见 vda
List of all bdev filesystems:
 erofs                                        ← ext4 是模块，此刻只有内建 erofs
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

死结：**驱动和文件系统在磁盘上的模块里，而磁盘要靠驱动和文件系统才能读**。　　

解法就是经典的两段式——先给一个临时的内存根（initramfs），在里面把模块装上、把真根挂出来，再切换过去。

## 2. 总体架构

```
┌─ QEMU ──────────────────────────────────────────────────────────┐
│ kernel(bzImage) + loader initrd + ext4 img(virtio 盘)           │
│                                                                 │
│  Stage1 initramfs (boot-initrd.img, ~7.7MB)               │
│    /init (busybox sh 脚本):                                     │
│      mount proc/sys/devtmpfs                                    │
│      insmod virtio_blk.ko → /dev/vda 出现                       │
│      insmod mbcache.ko jbd2.ko ext4.ko                          │
│      mount -t ext4 /dev/vda /newroot                            │
│      exec switch_root /newroot /init   ──────┐                  │
│                                              ▼                  │
│  Stage2 ext4 根 (rootfs-ext4.img, 512MB)                  │
│    /init = 业务脚本（跑测试/进 shell，随意）                     │
└─────────────────────────────────────────────────────────────────┘
```

- **loader initrd 是一次性的**：`switch_root` 释放 initramfs 内存后，它的使命就结束了。里面只放引导必需的最小集合。  
- **ext4 镜像才是"系统"**：全部用户态内容、测试镜像、业务 `/init` 都在里面，持久、可改、可挂到宿主机维护。

## 3. 两个镜像的构成

### 3.1 loader initrd (boot-initrd.img)
`boot-initrd.img`其实是个cpio.gz格式的压缩包　　

| 内容 | 来源 | 作用 |
|---|---|---|
| `/bin/busybox` + applet 链接 | 从原 initrd 解包 | 提供 sh/insmod/mount/switch_root 等 |
| `/lib/ld.so.0`,`ld64.so.0`,`libc.so.0`,`libm.so.0` | 同上 | **busybox 是动态链接的**（uClibc），少了库直接起不来 |
| `/ko/{virtio_blk,mbcache,jbd2,ext4}.ko` | 内核构建树 | 挂 ext4 盘的最小模块集 |
| `/init` | 自写脚本 | 装模块→挂盘→switch_root |
| `/dev/console`,`/dev/null` | gen_init_cpio spec 里的 `nod` 条目 | 内核给 PID 1 打开 stdio 要用 |

模块依赖链（`modinfo` 实测）：

```
virtio_blk.ko : 无依赖（CONFIG_VIRTIO=y 核心内建，virtio_ring 随之内建）
ext4.ko       : depends jbd2, mbcache
jbd2.ko       : 无依赖
mbcache.ko    : 无依赖
（crc16/crc32c 均为 =y 内建，无需携带）
```

装载顺序：`virtio_blk` → `mbcache` → `jbd2` → `ext4`。

### 3.2 ext4 根镜像（rootfs-ext4.img）

由原 `all-initrd.img` 解包而来（内容即原 initramfs 的全部用户态），两处改动：

1. `/init` 换成业务脚本；
2. 补齐 `/dev/console`、`/dev/null` 设备节点（非 root 解包 cpio 会丢设备节点）。

`/init`内容如下：
```
#!/bin/sh
exec >/dev/console 2>&1
mount -t proc proc /proc 2>/dev/null
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH
while true; do
	/bin/sh
	echo "[init] shell exited, respawning..."
done
```

## 4. 关键技术要点

### 4.1 rdinit 的"文件必须存在"语义

内核 `kernel_init_freeable()`：

```c
if (!ramdisk_execute_command)
	ramdisk_execute_command = "/init";
if (sys_access(ramdisk_execute_command, 0) != 0) {
	ramdisk_execute_command = NULL;
	prepare_namespace();        /* 放弃 initramfs，改挂真实根 */
}
```

`rdinit=` 指定的文件**在 initramfs 里必须真实存在**，否则内核静默放弃 initramfs 路径去挂真实根——于是看到 `unknown-block(0,0)` panic。  
loader 初版只有 `/bin/busybox` 没有 `/bin/sh` 链接，`rdinit=/bin/sh` 即因此失败。　 　
给 rdinit 配什么，cpio 里就得有什么。**

### 4.2 switch_root 干了什么

busybox `switch_root NEW_ROOT NEW_INIT`（要求以 PID 1 运行）：

1. 把 initramfs 上已挂载的 `/dev`（以及按版本不同可能含 /proc、/sys）**move-mount** 到新根下；  
2. 释放 initramfs 全部内存；  
3. 把 NEW_ROOT 变为 `/`，`exec` NEW_INIT——**PID 保持 1 不变**。  

所以 loader 里必须 `exec switch_root ...`（替换进程映像），不能把它当普通子进程调用后返回。

### 4.3 PID 1 绝对不可退出

内核规定 init 退出即 panic：`Attempted to kill init!`。

**结尾使用while循环可以避免执行exit后系统panic，可以常驻交互shell。**

### 4.4 initramfs 路径下 devtmpfs 不会自动挂载

`CONFIG_DEVTMPFS_MOUNT=y` 的自动挂载发生在 `prepare_namespace()` 里——而 initramfs 启动路径**跳过**了它。所以：

- 自动脚本路径（loader /init）：必须自己 `mount -t devtmpfs devtmpfs /dev`；  
- 交互路径（`rdinit=/bin/sh`）：同样没人替你挂——不挂 devtmpfs 就 insmod virtio_blk，`/dev/vda` 节点永远不会出现，  
  mount 报 `Can't lookup blockdev` / `No such file or directory`。

这是"rdinit=/bin/sh 后手工装模块却挂不上盘"的根因。

### 4.5 /dev/console 的来历

内核在 exec PID 1 之前要打开 `/dev/console` 作为其 stdio。  
initramfs 里没有它，init 输出直接丢失（现象是"起不来、无日志"）。

loader 的 console/null 节点由 gen_init_cpio 的 `nod` 条目保证；  
ext4 根里的节点是 switch_root 把 devtmpfs 搬过来兜底，另外也用 sudo mknod 实打实补进了镜像。

### 4.6 免 root 制作镜像的两件工具

- **`mke2fs -d <dir>`**（e2fsprogs ≥1.43）：  
  把目录内容直接灌进新建 ext4 镜像，**不需要 loop mount、不需要 root**。ext4 镜像由此生成。

- **`gen_init_cpio`**（内核源码 `usr/gen_init_cpio`，构建内核时已产出）：  
  按 spec 文本打 initramfs cpio，spec 里直接写 `nod /dev/console 600 0 0 c 5 1` 即可  
  **免 root 造设备节点**——普通 `cpio` 打包时非 root 会静默丢设备节点，这是大坑。

### 4.7 动态链接 busybox 的库必须随包

本 rootfs 的 busybox 是 uClibc 动态链接版（`readelf -d` 显示 NEEDED: libm.so.0, libc.so.0）。  
loader 里只放 busybox 二进制不放库，shell 根本 exec 不了。  
随包清单：`ld.so.0`（加载器本体）、`ld64.so.0`（指向它的符号链接，interpreter 路径）、`libc.so.0`、`libm.so.0`。

### 4.8 switch_root 不搬 /proc（本 busybox 版本）

busybox 1.20 的 switch_root 只搬 /dev，不搬 /proc、/sys。  
因此**新根里的 /init 必须自己重新 `mount -t proc proc /proc`**，否则进 ext4 后 `/proc/mounts` 都不存在。

### 4.9 其他小点

- loader 挂盘加 `-o rw` 还是 `ro` 均可；测试不需要写根时 `ro` 更稳。
- insmod 后到 `/dev/vda` 出现有微妙异步窗口，脚本里加了 `while [ ! -b /dev/vda ]` 等待循环。
- QEMU 用 `-enable-kvm` 时整个"引导"约 2~3 秒。我的编译环境是`x86 ubuntu`系统。

## 5. 完整制作步骤

`all-initrd.img`其实是我用`buildroot`构建出来的一个命令行工具较为完备的`rootfs.cpio.gz`文件。

### 5.1 解包原 initrd 并改造为 ext4 根

```bash
mkdir -p /tmp/rfs && cd /tmp/rfs
zcat /home/linux/all-initrd.img | cpio -idm --quiet
cp /tmp/init-ext4 init              # 换成业务 /init（自定）
chmod 755 init
# 非 root 解包丢了设备节点，用 sudo 补回
sudo mknod dev/console c 5 1 && sudo chmod 600 dev/console
sudo mknod dev/null    c 1 3 && sudo chmod 666 dev/null

# 免 root 生成 ext4 镜像
truncate -s 512M /home/linux/rootfs-ext4.img
mkfs.ext4 -q -F -d /tmp/rfs -L qemuroot \
    /home/linux/rootfs-ext4.img
```

### 5.2 制作 loader initrd

```bash
L=/tmp/erofs-loader
mkdir -p $L/{bin,lib,ko}
cp /tmp/rfs/bin/busybox                 $L/bin/
cp -a /tmp/rfs/lib/{ld.so.0,ld64.so.0,libc.so.0,libm.so.0} $L/lib/
K=/home/linux/kernel
cp $K/drivers/block/virtio_blk.ko $K/fs/mbcache.ko \
   $K/fs/jbd2/jbd2.ko $K/fs/ext4/ext4.ko      $L/ko/
# $L/init 内容见 5.3；别忘了 chmod 755

# gen_init_cpio spec（nod 条目免 root 造设备节点）
cat > /tmp/erofs-loader.spec <<EOF
dir /dev 755 0 0
nod /dev/console 600 0 0 c 5 1
nod /dev/null 666 0 0 c 1 3
dir /proc 755 0 0
dir /sys 755 0 0
dir /newroot 755 0 0
dir /bin 755 0 0
dir /lib 755 0 0
dir /ko 755 0 0
file /bin/busybox $L/bin/busybox 755 0 0
slink /bin/sh busybox 777 0 0
file /init $L/init 755 0 0
file /lib/ld.so.0 $L/lib/ld.so.0 755 0 0
slink /lib/ld64.so.0 ld.so.0 777 0 0
file /lib/libc.so.0 $L/lib/libc.so.0 755 0 0
file /lib/libm.so.0 $L/lib/libm.so.0 755 0 0
file /ko/virtio_blk.ko $L/ko/virtio_blk.ko 644 0 0
file /ko/mbcache.ko $L/ko/mbcache.ko 644 0 0
file /ko/jbd2.ko $L/ko/jbd2.ko 644 0 0
file /ko/ext4.ko $L/ko/ext4.ko 644 0 0
EOF
$K/usr/gen_init_cpio /tmp/loader.spec | gzip -9 \
    > /home/linux/boot-initrd.img
```

### 5.3 loader /init 全文

```sh
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox insmod /ko/virtio_blk.ko
/bin/busybox insmod /ko/mbcache.ko
/bin/busybox insmod /ko/jbd2.ko
/bin/busybox insmod /ko/ext4.ko
i=0
while [ ! -b /dev/vda ] && [ $i -lt 50 ]; do /bin/busybox sleep 0.1; i=$((i+1)); done
/bin/busybox mkdir -p /newroot
if /bin/busybox mount -t ext4 -o rw /dev/vda /newroot; then
	echo "loader: /dev/vda mounted as ext4, switching root"
	exec /bin/busybox switch_root /newroot /init
else
	echo "loader: EXT4 MOUNT FAILED, dropping to shell"
	exec /bin/busybox sh
fi
```

要点：`mount ... && exec switch_root` 的条件关系（4.3）、devtmpfs 先挂（4.4）、等 vda 出现。

## 6. QEMU 启动命令

```bash
qemu-system-x86_64 -enable-kvm -cpu host -m 8192 -smp 4 \
  -kernel /home/linux/kernel/arch/x86/boot/bzImage \
  -initrd /home/linux/boot-initrd.img \
  -drive file=/home/linux/rootfs-ext4.img,format=raw,if=virtio \
  -append "console=ttyS0 rdinit=/init" \
  -nographic -no-reboot
```

验证证据（实跑日志）：

```
virtio_blk virtio0: [vda] 1048576 512-byte logical blocks (537 MB/512 MiB)
EXT4-fs (vda): mounted filesystem ... r/w with ordered data mode
loader: /dev/vda mounted as ext4, switching root
/dev/vda / ext4 rw,relatime 0 0        ← /proc/mounts：根即 ext4
```

交互调试：把 `rdinit=/init` 换成 `rdinit=/bin/sh`，进 initramfs shell 后依次：

```
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev
insmod /ko/virtio_blk.ko; insmod /ko/mbcache.ko; insmod /ko/jbd2.ko; insmod /ko/ext4.ko
mount -t ext4 -o rw /dev/vda /newroot && exec switch_root /newroot /bin/sh
```

## 7. 故障案例速查

| 现象 | 根因 | 解法 |
|---|---|---|
| `unknown-block(0,0)` panic，分区列表空 | rdinit 指定的文件不在 initramfs 里（4.1） | 确认 cpio 内含该文件（如 `/bin/sh` 链接） |
| 交互下 `mount /dev/vda` 报 `Can't lookup blockdev` | 没挂 devtmpfs（4.4） | 先 `mount -t devtmpfs devtmpfs /dev` |
| `Attempted to kill init! exitcode=0` | PID 1 退出（脚本跑完/switch_root 失败后退出）（4.3） | 结尾 `exec /bin/sh`；命令用 `&&` 串联 |
| PID 1 无输出 | initramfs 缺 `/dev/console`（4.5） | gen_init_cpio spec 加 node 条目 |
| busybox 起不来 | 动态库没随包（4.7） | 带上 ld.so.0/libc.so.0/libm.so.0 |
| 进 ext4 后 /proc 为空 | switch_root 不搬 /proc（4.8） | 新根 /init 里重新 mount proc |

## 8. 与物理机的对应

两段式并非 QEMU 特有：物理机发行版内核要么把磁盘驱动和 ext4 编进内核（=y），  
要么由 dracut / mkinitcpio 生成的 initramfs 自动完成「装模块 → 挂真根 → switch_root」  
——**同样的两段式，只是由工具生成、无需手写**。  

真正的分水岭是根驱动 =y 还是 =m，而非运行环境：QEMU 上编成 =y 同样不需要两段式，  
物理机上全是 =m 且无 initramfs 同样起不来。  

本文方案的特殊之处是用极简自制 initramfs 替代 dracut；  
价值在于不改测试内核配置（避免全量重编 bzImage）就获得 ext4 常驻根文件系统的测试环境。