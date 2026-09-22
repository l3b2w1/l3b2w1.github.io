---
layout:     post
title:      EROFS trace fragment/ztailpacking reading-path
subtitle:   EROFS 跟踪 fragment/ztailpacking 读路径
date:       2026-09-22
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# EROFS fragment 与 ztailpacking：读路径实测

读 14 专题时最容易卡住的地方是：**fragment 和 ztailpacking 到底在读路径上差在哪**。
两者都跟「文件尾部那点数据」有关，但一个把数据放进 **packed inode**，
另一个把数据**内联进 inode 自己的元数据区**。

光看代码不够直观，于是造了三个对照镜像，用同一套 ftrace 手法各抓一次读路径：

- **实验 A** — `plain.erofs`：普通压缩（对照）
- **实验 B** — `frag.erofs`：`-Eall-fragments`，数据整份进 packed inode
- **实验 C** — `ztail.erofs`：`-Eztailpacking`，尾部数据内联进 inode

## 结论速览

区别在于**数据最后从哪拿出来**：

| 实验 | 数据在哪 | 怎么拿到 | `erofs_bread` | 去噪后行数 |
|---|---|---|---|---|
| A 普通压缩 | pcluster（压缩块） | kthread 解压 | 11 | 564 |
| B fragment | **packed inode** | 逐块读 + memcpy | **93** | 1071 |
| C ztailpacking | **inode 元数据区** | 随元数据 buffer 到位 | 6 | 60 |

`erofs_bread` 的次数是最直观的判别量——B 段是 A 段的八倍多。

## 0. 环境

| 项 | 值 |
|---|---|
| 宿主机内核 | `5.10.0`（本机，**不是**被测内核，别混） |
| VM 内核源码 | `/home/linux/erofs/linux-stable`，`v7.3-rc3-60-g587858367581` |
| VM 内核镜像 | `/home/linux/erofs/linux-stable/arch/x86/boot/bzImage` |
| VM initrd | `/home/linux/erofs/erofs-boot-initrd.img` |
| VM 根文件系统 | `/home/linux/erofs/erofs-rootfs-ext4.img`（ext4，busybox） |
| 被测镜像 | 打包进 rootfs 的 `/images/{plain,frag,ztail}.erofs` |
| 9p 共享 | `-virtfs local,path=/home/linux/erofs,mount_tag=host`<br>⇒ 宿主机 `/home/linux/erofs` == VM 内 `/host` |
| mkfs | `/opt/erofs-utils/bin/mkfs.erofs` 1.9.4 |

## 1. 造三个镜像

```bash
cd /home/linux/erofs/fragment
mkdir -p src

# 三类测试数据
for i in 1 2 3 4; do head -c 300000 /dev/urandom > src/rnd$i.bin; done   # 压不动 → 留零头
yes "the quick brown fox jumps over the lazy dog" | head -c 200000 > src/text.bin
yes "abcabcabc" | head -c 1024 > src/small.bin                          # 小、可压缩

MKFS=/opt/erofs-utils/bin/mkfs.erofs
DUMP=/opt/erofs-utils/bin/dump.erofs

$MKFS -b4096 -zlz4                 plain.erofs src
$MKFS -b4096 -zlz4 -Eall-fragments frag.erofs  src
$MKFS -b4096 -zlz4 -Eztailpacking  ztail.erofs src
```

验证特性位：

```
  plain.erofs  :             lz4_0padding
  frag.erofs   :             lz4_0padding fragments dedupe
  ztail.erofs  :             lz4_0padding ztailpacking
```

两个值得记住的点：

1. **选项名是 `all-fragments`（连字符）**。写成 `all_fragments` 会报
   `failed to open image file` —— 一个完全误导的错误，我第一次就在这卡住了。
2. `frag.erofs` 同时显示 **`fragments dedupe`**，因为
   `EROFS_FEATURE_INCOMPAT_DEDUPE` 与 `..._FRAGMENTS` **都是 0x00000020**（位别名）。
   15 专题「误解 6」写的就是这个，这里在真实镜像上看到了。

再看文件落点（`-Eall-fragments` 下整份数据都在 packed inode）：

```
Size: 300000  On-disk size: 0  regular file
NID: 45   Layout: 1
 Ext:   logical offset   |  length :     physical offset    |  length
   0:        0..  300000 |  300000 :          0..         0 |       0
```

**on-disk size = 0**、extent `0..0`：主设备上一块都没占。

## 2. 把镜像打包进 ext4 rootfs

镜像要能在 VM 里挂上。这次的做法是**直接打进 ext4 rootfs**，VM 启动后就在 `/images/` 下。

```bash
mkdir -p /mnt/ext4root
mount -o loop /home/linux/erofs/erofs-rootfs-ext4.img /mnt/ext4root
df -h /mnt/ext4root
umount /mnt/ext4root
truncate -s +128M erofs-rootfs-ext4.img          # 190MB → 324MB
/sbin/e2fsck -f -y erofs-rootfs-ext4.img         # resize2fs 前必须做
/sbin/resize2fs erofs-rootfs-ext4.img            # 46547 → 79315 blocks

mount -o loop /home/linux/erofs/erofs-rootfs-ext4.img /mnt/ext4root
mkdir -p /mnt/ext4root/images
cp /home/linux/erofs/fragment/{plain,frag,ztail}.erofs /mnt/ext4root/images/
umount /mnt/ext4root                             # ★ 必须卸载，否则 QEMU 拿不到写锁
```

> 不卸载的话 QEMU 会报 `Failed to get write lock / Is another process using the image`。

跑之前确认环境干净：

```bash
pgrep -c qemu-system ; mount | grep erofs-rootfs    # 两者都应为 0
```

## 3. 起 VM

镜像已经在 rootfs 里，所以**只要一块盘**；9p 仍要保留（trace log 要写回宿主机）：

```bash
cd /home/linux/erofs/linux-stable
qemu-system-x86_64 -m 8192 -smp 4 -nographic \
  -kernel arch/x86/boot/bzImage --enable-kvm \
  -initrd /home/linux/erofs/erofs-boot-initrd.img \
  -append "console=ttyS0 rdinit=/init" \
  -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
  -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
  -monitor none -no-reboot
```

VM 内要做的三件事（手工版见 §7）。不想手工敲就用脚本一次喂进去：

```sh
{ sleep 10; cat vm-cmds.txt; } \
    | timeout 420 /usr/bin/script -q -c "$QEMU_CMD" /dev/null > trace-fragment.log 2>&1
```

busybox sh 会**顺序执行**命令，所以一次喂完即可；只需喂之前 `sleep 10` 等 shell 起来，
末尾放 `poweroff -f` 让 VM 关机（QEMU 随之退出，`script` 才结束）。

## 4. VM 内：挂载 + ftrace（三个实验共用）

```sh
# 9p：把宿主机 /home/linux/erofs 挂进来（trace log 要写回宿主机）
mkdir -p /host
mount -t 9p -o trans=virtio,version=9p2000.L host /host

# 三个镜像同时挂需要 3 个 loop，VM 的 /dev 下默认只有 loop0 —— 补节点（主设备号 7）
for i in 0 1 2 3; do ls /dev/loop$i >/dev/null 2>&1 || mknod /dev/loop$i b 7 $i; done

mkdir -p /mnt/plain /mnt/frag /mnt/ztail
mount -t erofs /images/plain.erofs /mnt/plain ; echo "MOUNT_plain=$?"
mount -t erofs /images/frag.erofs  /mnt/frag  ; echo "MOUNT_frag=$?"
mount -t erofs /images/ztail.erofs /mnt/ztail ; echo "MOUNT_ztail=$?"
mount | grep erofs
```

三个都是 `=0`。挂载靠 busybox 自动分配 loop（源是 rootfs 里的普通文件）。

ftrace 配置（三段共用，只换读的文件）：

```sh
cd /sys/kernel/tracing
echo 0 > tracing_on
echo > trace
echo > set_graph_function
echo > set_ftrace_filter
echo nop > current_tracer
echo 512 > buffer_size_kb
echo function_graph > current_tracer
echo __x64_sys_read >> set_graph_function      # 根函数，见下方说明
echo 0 > options/funcgraph-irqs
echo 1 > options/funcgraph-abstime
# set_graph_notrace：锁 / 调度 / 时间 / tty / RCU 等（完整列表见 trace-fragment.sh）
```

⚠️ **根函数必须是 `__x64_sys_read`**。`vfs_read` / `ksys_read` / `do_mount` 这些
在同一编译单元被内联，  
虽然在 `/proc/kallsyms` 里有符号，但 ftrace 插桩的函数体
运行时根本进不去，**实测 0 命中**。

每次抓取的固定套路：

```sh
echo > trace
echo 3 > /proc/sys/vm/drop_caches     # 冷读，保证走真实路径
echo 1 > tracing_on
dd if=<文件> of=/dev/null bs=4096 count=8
echo 0 > tracing_on
cat trace > /host/fragment/graph-<段>.log     # ★ 写 9p，别 cat 到串口
```

> 几 MB 的 trace 从串口倒出来会把串口堵死、VM 直接断线（日志停在半行）。

## 5. 实验 A：普通压缩（对照）

[graph-A_PLAIN.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-22-erofs-graph-A_PLAIN.log)

读 `/mnt/plain/text.bin`，结果 `graph-A_PLAIN.log`（5201 行）。

去噪后（只留 EROFS 函数）的骨架：

```
z_erofs_readahead()
  z_erofs_pcluster_readmore()                 ← 顺带预读相邻 pcluster
    z_erofs_map_blocks_iter()
      z_erofs_map_blocks_fo()
        z_erofs_load_lcluster_from_disk()
          erofs_read_metabuf() → erofs_bread()
  z_erofs_scan_folio()
    erofs_onlinefolio_init() / _split() / _end()
  z_erofs_runqueue()                          ← 解压交给 pcpu kthread
```

**一句话**：数据来自压缩块，路径是「映射 → 读元数据 → 解压」，  
解压动作在kthread 里（`z_erofs_do_decompressed_bvec` 45 次），调用者不直接看到解压细节。

## 6. 实验 B：fragment（数据都在 packed inode）

[graph-B_FRAGMENT.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-22-erofs-graph-B_FRAGMENT.log)

读 `/mnt/frag/rnd1.bin`，结果 `graph-B_FRAGMENT.log`（9454 行）。

去噪后的骨架：

```
z_erofs_read_folio()
  z_erofs_pcluster_readmore()
    z_erofs_map_blocks_iter()
      z_erofs_map_blocks_fo()
        z_erofs_load_lcluster_from_disk()
          erofs_read_metabuf() → erofs_bread()
  z_erofs_scan_folio()
    erofs_onlinefolio_init()
    erofs_bread()                             ★ 直接调，不经过 erofs_read_metabuf
      read_cache_folio()                      ← 走 packed_inode->i_mapping
    erofs_put_metabuf()                       ★ 收尾，读一段调一次
  z_erofs_runqueue()
    erofs_map_dev()
    z_erofs_decompress_kickoff()
```

### ★ `z_erofs_read_fragment` 抓不到，但能认定它确实在跑

它是 `static` 且被编译器内联 —— `nm vmlinux` 里**根本没有这个符号**，  
所以 ftrace 永远抓不到它的独立函数体（跟 `vfs_read` 那类问题同源）。

**看调用关系就能认定**：源码里它的结构是
「循环 `erofs_bread` + `memcpy_to_folio`，出循环 `erofs_put_metabuf`」，
内联后这俩就挂在 `z_erofs_scan_folio` 下面。实测：

| 函数 | A 普通 | B fragment | C ztailpacking |
|---|---|---|---|
| `erofs_bread` | 11 | **93** | 6 |
| `erofs_put_metabuf` | 3 | **49** | 2 |
| `erofs_map_blocks` | 13 | **92** | 7 |

**`put_metabuf` 比 `bread` 更具指向性**——A 段只有 3 次，B 段 49 次。  
**一句话**：fragment 的数据要一块一块从 packed inode 里 `erofs_bread` 出来，
再 memcpy 进 folio；无需解压。

## 7. 实验 C：ztailpacking（尾部 inline 在元数据区）

[graph-C_ZTAILPACKING.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-22-erofs-graph-C_ZTAILPACKING.log)

读 `/mnt/ztail/small.bin`（1024 字节、可压缩），结果只有 **368 行**。

```sh
# inline 数据在文件尾部，读头部抓不到；小文件更容易整份 inline
dd if=/mnt/ztail/small.bin of=/dev/null bs=4096 count=8
```

去噪后骨架：

```
z_erofs_scan_folio()
  erofs_onlinefolio_init()
  z_erofs_map_blocks_iter()
    erofs_read_metabuf() → erofs_bread()      ← 读的是元数据
    z_erofs_map_blocks_fo()
      z_erofs_load_lcluster_from_disk()
```

**一句话**：映射时置 `EROFS_MAP_META`（`zmap.c`），尾部 inline 数据（`z_idata_size`）
就放在 inode 的元数据区，  
随元数据 buffer 一起到位——**没有额外的 packed inode 读取，也不需要解压**。  
trace 只有 368 行（去噪后 60 行）正是这个原因。

> 如果读的是大文件的头部，C 段看起来会和 A 段差不多 —— inline 数据只在尾部。

## 8. 三段对比

| 观测量 | A 普通 | B fragment | C ztailpacking |
|---|---|---|---|
| trace 行数 | 5201 | 9454 | 368 |
| `erofs_bread` | 11 | **93** | 6 |
| `erofs_put_metabuf` | 3 | **49** | 2 |
| `erofs_map_blocks` | 13 | **92** | 7 |
| `z_erofs_do_decompressed_bvec` | 45 | 24 | 1 |
| `z_erofs_runqueue` | 6 | **48** | 2 |
| `erofs_iomap_begin/next` | 0 | 0 | 0 |
| **数据落地方式** | kthread 解压 | packed inode 逐块 memcpy | 元数据区直取 |

三点说明：

1. **`erofs_iomap_*` 全是 0** —— 因为这三个文件都是压缩的，走 `z_erofs_*`；    
   iomap 是非压缩/flat 文件才走的路（13 专题的 chunk 文件就是走 `erofs_iomap_begin`）。
   两个专题的 trace 一对照，这两条路很清楚。
2. 三段**共用同一条公共前缀**：  
   `__x64_sys_read → ksys_read → vfs_read → erofs_file_read_iter → filemap_read →
   page_cache_sync_ra → page_cache_ra_order → do_page_cache_ra →
   page_cache_ra_unbounded → z_erofs_readahead`。  分叉发生在 `z_erofs_scan_folio()` 内部。
3. 换个递送方式不影响结论：这次是「ext4 内的文件 + loop」，上一版是「额外 virtio 盘」，
   `erofs_bread` 93 vs 85，量级一致。

## 9. 去噪：只留 EROFS 内部调用图

完整 trace 里九成是 VFS / mm / 锁 / 调度的噪声。`trace-erofs-only.sh` 做后处理：

```bash
sh trace-erofs-only.sh                                # 处理三段
sh trace-erofs-only.sh graph-B_FRAGMENT.log out.txt   # 或只处理一个
```

核心就一句（保留缩进 = 调用层级）：

```sh
awk -F"|" "{print \$NF}" graph-X.log | grep -aE "erofs_|z_erofs_"
```

| 段 | 原 | 去噪后 |
|---|---|---|
| A plain | 5201 | **564** |
| B fragment | 9454 | **1071** |
| C ztailpacking | 368 | **60** |

⚠️ **为什么不在 ftrace 里直接过滤干净**：试过把 graph 根设成 EROFS 自己的入口
（`trace-fragment-erofsonly.sh`：`erofs_file_read_iter` / `z_erofs_readahead` /
`z_erofs_scan_folio` / `z_erofs_map_blocks_iter`），但 function_graph 一旦开始展开，
erofs 调用的 VFS 函数（`filemap_*`、`page_cache_*`、`workingset_*`…）照样被带出来
（产物 `raw-eo-*.log` 可作对照）。**宿主机侧后处理才是干净的**。

## 10. 注意事项（都是踩过的）

1. **`-Eall-fragments` 是连字符**。写成 `all_fragments` → `failed to open image file`（误导性报错）
2. **`z_erofs_read_fragment` 抓不到**（static + 内联），靠 `erofs_bread` + `erofs_put_metabuf`
   成对出现来认定
3. **根函数别用 `vfs_read` / `ksys_read` / `do_mount`**（内联，0 命中），用 `__x64_sys_read`
4. **ztailpacking 的 inline 数据在文件尾部**，读头部抓不到；小文件更容易整份 inline
5. **ext4 rootfs 空间为 0** → 扩容（`truncate` + `e2fsck -f` + `resize2fs`）  
6. **改完 rootfs 必须 `umount`**，否则 QEMU 报 `Failed to get write lock`
7. **VM 的 `/dev` 只有 loop0** → 三个镜像同时挂要 `mknod /dev/loopN b 7 N`（loop 主设备号 7；
   virtio 是 253）
8. **trace 别 `cat` 到串口**（堵死串口、VM 断线），写 9p 文件

## 12. 附录：纯手工操作全流程命令清单

> 前面各节的命令已可按阶段执行，这里再按「从 0 到拿到结果」串一遍，方便直接照抄。

### 阶段 1：造镜像

```bash
mkdir -p src
for i in 1 2 3 4; do head -c 300000 /dev/urandom > src/rnd$i.bin; done
yes "the quick brown fox jumps over the lazy dog" | head -c 200000 > src/text.bin
yes "abcabcabc" | head -c 1024 > src/small.bin
MKFS=/opt/erofs-utils/bin/mkfs.erofs
$MKFS -b4096 -zlz4                 plain.erofs src
$MKFS -b4096 -zlz4 -Eall-fragments frag.erofs  src
$MKFS -b4096 -zlz4 -Eztailpacking  ztail.erofs src
```

### 阶段 2：打包进 ext4

```bash
cd /home/linux/erofs
mount -o loop /home/linux/erofs/erofs-rootfs-ext4.img /mnt/ext4root
df -h /mnt/ext4root                     # Avail 大概率为 0
umount /mnt/ext4root
truncate -s +128M erofs-rootfs-ext4.img
/sbin/e2fsck -f -y erofs-rootfs-ext4.img
/sbin/resize2fs erofs-rootfs-ext4.img
mount -o loop /home/linux/erofs/erofs-rootfs-ext4.img /mnt/ext4root
cp /home/linux/erofs/fragment/{plain,frag,ztail}.erofs /mnt/ext4root/images/
umount /mnt/ext4root
```

### 阶段 3：起 VM —— 见 §3

### 阶段 4：VM 内挂载 + 三段抓取 —— 见 §4 / §5 / §6 / §7

### 阶段 5：宿主机侧统计与去噪

```bash
cd /home/linux/erofs/fragment
wc -l graph-*.log
for f in A_PLAIN B_FRAGMENT C_ZTAILPACKING; do
  g=graph-$f.log
  printf "%-18s bread=%-5s put_metabuf=%-5s map_blocks=%s\n" "$f" \
    "$(grep -c erofs_bread $g)" "$(grep -c erofs_put_metabuf $g)" "$(grep -c erofs_map_blocks $g)"
done
sh trace-fragment-erofsonly.sh
```

[trace-erofs-only shell script](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-22-erofs-trace-fragment-erofsonly.sh)

[trace fragment full shell script](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-22-erofs-trace-fragment.sh)
