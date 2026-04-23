---
layout:     post
title:      overlayfs usage
subtitle:   kfuzztest 原理与实践
date:       2026-04-23
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - fs
---

# 手记：一个嵌入式init脚本里的overlay+squashfs玩法

最近在翻一个嵌入式设备的initrd脚本，挺典型的。  
顺手把它的工作过程理了一遍，核心就一件事：  
**用只读的squashfs做系统底包，再用内存里的tmpfs做可写层，拼出一个能读写但重启就还原的根文件系统**。

下面是脚本的完整逻辑，我按执行顺序说一下。

## 1. 先把基础环境搭起来

```bash
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
mount -t devpts devpts /dev/pts
```

没什么好说的，initrd里干活前都得先挂上这几样，/proc、/sys、/dev 一个不能少。

## 2. 挂载两个flash分区（yaffs2）

```bash
FLASH_DEV0=/dev/mtdblock0   → /mnt/flash
FLASH_DEV1=/dev/mtdblock1   → /mnt/squashfs
```

注意这里第二个分区虽然名字叫 `squashfs`，但它本身还是 yaffs2 读写分区，  
后面会用 squashfs 镜像再挂一层上去。两个分区都是可写的，但最终用法不一样。

## 3. 把 squashfs 镜像弄到 flash 上

脚本检查 `/mnt/squashfs/rarely-used.squashfs` 存不存在，  
没有的话就从 initramfs 根目录的 `/rarely-used.squashfs` 复制过去。  
这意味着：固件里自带一个默认 squashfs 镜像，第一次启动时自动部署到 flash 分区。  
以后想升级系统，只要替换这个文件就行，不用重烧整个 flash。

## 4. 用 loop 挂载 squashfs 镜像（只读）

```bash
mount -t squashfs -o loop,ro /mnt/squashfs/rarely-used.squashfs /mnt/squashfs
```

这一步有点绕：`/mnt/squashfs` 本身是一个 yaffs2 分区（里面有镜像文件），  
现在用 loop 方式把那个镜像文件以只读 squashfs 挂载到**同一个目录**上。  
挂载之后，原来分区里的文件就被“盖住”了，剩下的是 squashfs 解出来的系统内容。  
这种做法在嵌入式里很常见，能省一个挂载点。

## 5. 准备 overlay 的 upper 层（全在内存里）

```bash
mount -t tmpfs tmpfs /mnt/overlay
mkdir /mnt/overlay/{upper,work}
```

upper 和工作目录都放在 tmpfs 上，也就是所有写入操作最后都落在内存里。  
重启后改动全丢，但好处是不伤 flash，而且速度快。

## 6. 把 initramfs 里的基础目录复制到 upper

```bash
for d in usr bin sbin lib etc var opt; do
    cp -ar "/$d" /mnt/overlay/upper/
done
```

这点挺关键的：后面 `switch_root` 到新根时，新根里的 /bin、/sbin、/etc 从哪来？  
就是从当前 initramfs 里 copy 过去。
代价是内存占用会增加，不过对于现代嵌入式设备（几百兆内存）来说问题不大。  
如果你内存很紧张，可以考虑用 `mount --bind` 或者只复制最精简的部分。

## 7. 挂载最终的 overlay 根

```bash
mount -t overlay overlay \
  -o lowerdir=/mnt/squashfs,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work \
  /mnt/merged
```

- **lowerdir**：只读的 squashfs（真正的系统文件）
- **upperdir**：内存 tmpfs（所有写操作落这里）
- **workdir**：overlay 内部用，也必须在 tmpfs 上

挂载结果在 `/mnt/merged`，这就是我们未来的新根。

## 8. 迁移挂载点到新根下

```bash
mkdir -p /mnt/merged/{proc,sys,dev,tmp,root,var,mnt/{flash,squashfs,overlay}}
mount --move /proc /mnt/merged/proc
mount --move /sys  /mnt/merged/sys
mount --move /dev  /mnt/merged/dev
mount --move /tmp  /mnt/merged/tmp
mount --move /mnt/flash    /mnt/merged/mnt/flash
mount --move /mnt/squashfs /mnt/merged/mnt/squashfs
mount --move /mnt/overlay  /mnt/merged/mnt/overlay
```

把当前跑着的 proc、sys、dev 还有那三个工作目录都搬到新根的对应位置，保证 `switch_root` 之后路径不乱。

## 9. 脚本末尾还顺手打了启动耗时

```bash
start=$(cat /proc/uptime ...)
end=$(cat $MERGED_DIR/proc/uptime ...)
echo ... > /dev/kmsg
```

这个小细节挺实用，能在内核日志里看到 initrd 阶段花了多少秒，排查启动慢的问题时很有用。

## 10. 最后切根，启动 /sbin/init

```bash
exec switch_root /mnt/merged /sbin/init
```

一旦切过去，initramfs 的内存就释放了，系统进入正常的用户态启动流程。

## 这个脚本解决了什么问题？

说白了几点：

- **延长 flash 寿命**：系统文件全在 squashfs 只读分区，不会因为频繁写日志或临时文件而磨损 NAND。
- **运行时可写，但重启还原**：/etc、/var、用户安装的程序等如果没做额外持久化，改完重启就恢复，很适合一些固定功能的嵌入式设备。
- **容易升级**：换掉 `/mnt/squashfs/rarely-used.squashfs` 这个文件，下次启动就是新系统。
- **便于调试**：脚本里但凡 mount 失败或者文件缺失，就 `exec /bin/sh` 掉进 shell，不会卡在 kernel panic。

## 总结

总的来说，这是嵌入式 Linux 上一套很成熟的“只读根文件系统 + 内存覆盖”方案。  
看懂这一个脚本，基本就理解了 OverlayFS、squashfs、initrd 切换根的配合套路。

## 完整脚本
```
#!/bin/sh
FLASH_DEV0=/dev/mtdblock0
FLASH_DEV1=/dev/mtdblock1

FLASH_DIR=/mnt/flash
SQUASH_DIR=/mnt/squashfs

SQUASH_IMG="$SQUASH_DIR/rarely-used.squashfs"

OVERLAY_DIR=/mnt/overlay
MERGED_DIR=/mnt/merged

# 1. 基础虚拟文件系统
mount -t proc proc /proc
start=$(cat /proc/uptime | awk '{print $1}')
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp

mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

# 2. 加载内核模块

# 3. 挂载 flash
mkdir -p "$FLASH_DIR"

if ! mount -t yaffs2 -o rw,noatime,user_xattr "$FLASH_DEV0" "$FLASH_DIR"; then
	echo "mount flash failed"
	exec /bin/sh
fi
echo "flash mounted"

mkdir -p "$SQUASH_DIR"
if ! mount -t yaffs2 -o rw,noatime,user_xattr "$FLASH_DEV1" "$SQUASH_DIR"; then
	echo "mount flash failed"
	exec /bin/sh
fi
echo "flash mounted"

# 4. 准备 squashfs 镜像
if [ ! -f "$SQUASH_IMG" ]; then
	echo "copy rarely-used.squashfs to flash"
	cp /rarely-used.squashfs "$SQUASH_IMG"
	sync
fi
[ -f "$SQUASH_IMG" ] || { echo "missing $SQUASH_IMG"; exec /bin/sh; }

# 5. 挂载 squashfs
if [ -f "$SQUASH_IMG" ]; then
	mount -t squashfs -o loop,ro "$SQUASH_IMG" "$SQUASH_DIR"
fi

# 6. 准备 overlay upper/work（RAM）
mkdir -p "$OVERLAY_DIR"
mount -t tmpfs tmpfs "$OVERLAY_DIR"

mkdir -p "$OVERLAY_DIR/upper"
mkdir -p "$OVERLAY_DIR/work"

# 7. 把 initramfs 里要保留的基础内容放到 upper
for d in usr bin sbin lib etc var opt; do
	if [ -e "/$d" ]; then
		cp -ar "/$d" "$OVERLAY_DIR/upper/"
	fi
done

# 8. 挂载最终 root overlay
#    upper: RAM initramfs
#    lower: squashfs
mkdir -p "$MERGED_DIR"

LOWERDIR="$SQUASH_DIR"

mount -t overlay overlay \
	-o lowerdir="$LOWERDIR",upperdir="$OVERLAY_DIR/upper",workdir="$OVERLAY_DIR/work" \
	"$MERGED_DIR"

if [ $? -ne 0 ]; then
	echo "overlay mount failed"
	exec /bin/sh
fi

# 10. 新根所需挂载点
mkdir -p "$MERGED_DIR/root"
mkdir -p "$MERGED_DIR/proc"
mkdir -p "$MERGED_DIR/sys"
mkdir -p "$MERGED_DIR/dev"
mkdir -p "$MERGED_DIR/dev/pts"
mkdir -p "$MERGED_DIR/tmp"
mkdir -p "$MERGED_DIR/var"
mkdir -p "$MERGED_DIR/mnt/flash"
mkdir -p "$MERGED_DIR/mnt/squashfs"
mkdir -p "$MERGED_DIR/mnt/overlay"

# 11. 移动挂载点到新根
mount --move /proc "$MERGED_DIR/proc"
mount --move /sys "$MERGED_DIR/sys"
mount --move /dev "$MERGED_DIR/dev"
mount --move /tmp "$MERGED_DIR/tmp"

mount --move "$FLASH_DIR" "$MERGED_DIR/mnt/flash"
mount --move "$SQUASH_DIR" "$MERGED_DIR/mnt/squashfs"
mount --move "$OVERLAY_DIR" "$MERGED_DIR/mnt/overlay"

end=$(cat $MERGED_DIR/proc/uptime | awk '{print $1}')
echo "squashfs.sh runtime beg $start" > /dev/kmsg
echo "squashfs.sh runtime end $end" > /dev/kmsg

# 13. 切换 root 启动 init
exec switch_root "$MERGED_DIR" /sbin/init

echo "switch_root failed"
exec /bin/sh
```
