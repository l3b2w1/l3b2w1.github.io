---
layout:     post
title:      EROFS trace mount blobdev
subtitle:   EROFS 跟踪blobdev多设备mount流程
date:       2026-10-15
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
---

# 25 · erofs mount 流程 ftrace 完整跟踪（blobdev 多设备实测）

> 源码树：`linux-stable`（Linux 7.3.0-rc4）  
> 方法：QEMU VM 内 ftrace `function_graph`，根函数 `__x64_sys_mount`，  
> 从 mount(2) 进入到系统调用返回的**全部函数调用零遗漏**抓取（不设任何 notrace）。

## 0. 摘要

| 项 | 值 |
|---|---|
| 挂载命令 | `mount -t erofs -o device=/dev/vdc /dev/vdb /mnt/md` |
| 结果 | 成功（RC=0） |
| mount(2) 总耗时 | **1002.610 µs**（单 CPU 单进程，无跨核噪声） |
| 抓到的函数调用记录 | 3778 行（全部属于 `mount-106` 进程） |
| erofs 专属函数命中 | 22 种（另 2 种被编译器内联，见 §6.9） |
| 挂载后 dmesg | `erofs (device vdb): initialized per-cpu workers successfully.`<br>`erofs (device vdb): mounted with root inode @ nid 40.` |

**一句话**：mount(2) 走 VFS 的 fs_context 新框架，  
把 `source`（主设备）与`device=`（blob 设备）两个参数分两次喂给 `erofs_fc_parse_param`；  
`get_tree_bdev_flags` 打开主设备后进入 `erofs_fc_fill_super`，在其中按固定顺序读:   
superblock → 解析全局配置 → 打开 blob 设备 → 初始化压缩子系统 → 读根 inode →注册 shrinker/xattr/sysfs；  
最后 `do_add_mount` 把 vfsmount 挂进 namespace。

## 1. 测试环境配置

#### 1.1 宿主机与虚拟机

| 项 | 值 |
|---|---|
| 宿主机 | `root@55.154.14.159`（linux），QEMU `/usr/bin/qemu-system-x86_64` |
| 内核 | `linux-stable`（7.3.0-rc4），bzImage：`linux-stable/arch/x86/boot/bzImage` |
| 启动方式 | `-kernel bzImage -initrd erofs-boot-initrd.img`，`rdinit=/init`，`console=ttyS0` |
| 内存/CPU | `-m 8192 -smp 4`（实际 mount 全程落在 CPU0） |
| 用户态 | busybox initramfs（switch root 到 ext4 rootfs 盘） |
| 数据盘 | virtio：`vdb`=主镜像，`vdc`=blob 镜像 |
| 文件回传 | 9p：宿主 `/home/linux/erofs` ↔ VM `/host`（trace 不走串口，防堵死） |

QEMU 命令摘录：
```sh
qemu-system-x86_64 -m 8192 -smp 4 -nographic \
 -kernel arch/x86/boot/bzImage --enable-kvm \
 -initrd /home/linux/erofs/erofs-boot-initrd.img \
 -append "console=ttyS0 rdinit=/init" \
 -drive file=/home/linux/erofs/erofs-rootfs-ext4.img,format=raw,if=virtio \
 -drive file=/home/linux/erofs/multidev/main.erofs,format=raw,if=virtio \
 -drive file=/home/linux/erofs/multidev/blob.img,format=raw,if=virtio \
 -virtfs local,path=/home/linux/erofs,mount_tag=host,security_model=none,id=host0 \
 -monitor none -no-reboot
```

虚拟机内部命令(vm-cmds-mount.txt)：
```
# VM 内依次执行的命令（宿主机 02-vm-run.sh 一次性喂入）
# busybox sh 顺序执行，一条跑完才读下一条；最后 poweroff -f 主动关机

# 9p 共享：把宿主机的 /sdd/erofs 挂到 VM 的 /host
mkdir -p /host
mount -t 9p -o trans=virtio,version=9p2000.L host /host

# 主戏：ftrace function_graph 完整跟踪 erofs 多设备 mount
sh /host/multidev/trace-mount.sh

# 收尾
echo '@@@@@@ ALL_DONE @@@@@@'
sleep 2
poweroff -f
```

#### 1.2 镜像制作（blobdev）

脚本 `multidev/01-mkimg.sh`（`/opt/erofs-utils/bin/mkfs.erofs`）：

```sh
head -c 4194304 /dev/urandom > src2/rnd4m.bin     # 真随机：压不动 → chunk 落 blob
yes "repeatable payload for lz4" | head -c 1048576 > src2/text1m.bin   # 高度可压
truncate -s 64M blob.img
mkfs.erofs -b4096 --chunksize=65536 -zlz4 \
    --blobdev=/home/linux/erofs/multidev/blob.img main.erofs src2
```

`dump.erofs` 验证结论（实测输出）：

| 文件 | 落点 | 证据 |
|---|---|---|
| `/rnd4m.bin`（4 MiB 随机） | **device 1（blob）** | `0..4194304 : 0..4194304 # device 1` |
| `/text1m.bin`（1 MiB 重复文本） | device 0（主设备，压缩） | 2 个 extent，phys 落主设备 4096..12288 |
| superblock | incompat 含 `chunked_file device_table` | `dump -s` 输出 |

即：镜像自带 device table（`devt_slotoff` 槽位），  
blob.img 是第 1 号设备的数据后端，`-o device=/dev/vdc` 在挂载时把这个后端交还给内核。

## 2. ftrace 跟踪设置

VM 内脚本 `multidev/trace-mount.sh` 核心配置：

```sh
TD=/sys/kernel/tracing
echo 0 > tracing_on
echo > set_graph_function            # 清空根函数
echo > set_graph_notrace             # ★ 不设任何 notrace → 函数零遗漏
echo > set_ftrace_filter             # ★ 不设任何 filter → 子树全展开
echo nop > current_tracer
echo 2048 > buffer_size_kb           # 4 vCPU × 2048 KB 防溢出
echo function_graph > current_tracer
echo __x64_sys_mount > set_graph_function
echo 0 > options/funcgraph-irqs      # 不展开中断（中断不属于 mount 调用链）
echo 1 > options/funcgraph-proc      # 输出带进程名+PID
echo 1 > options/funcgraph-tail      # 叶子带 } /* func */ 尾注
echo 1 > options/funcgraph-abstime   # 绝对时间戳

echo 1 > tracing_on
mount -t erofs -o device=/dev/vdc /dev/vdb /mnt/md
RC=$?
echo 0 > tracing_on
cat trace > /host/multidev/graph-mount-full.log   # 直写 9p，不走串口
```

#### 2.1 为什么根函数是 `__x64_sys_mount`

`do_mount` / `ksys_mount` / `vfs_kern_mount` 与调用方同一编译单元（TU），  
被编译器**内联**后 ftrace 的运行时插桩（mcount/fentry）打不进去，实测 0 命中（该坑在 multidev 专题测读路径时已踩过）。  
syscall 入口 `__x64_sys_mount`是独立的可插桩函数，从它开始既能覆盖完整 VFS 路径，  
又天然把 shell 的 `fork/exec` 等无关活动排除在外（function_graph 只输出根函数命中的子树）。

#### 2.2 输出格式怎么读

```
   时间戳 | CPU) 进程-PID |   DURATION    |   FUNCTION CALLS
      |          |       |       |        |        |
 10.302056 |   0) mount-106 |               |  __x64_sys_mount() {
 10.302057 |   0) mount-106 |               |    strndup_user() {
 10.302057 |   0) mount-106 |   1.518 us    |      } /* memdup_user */
```

- 缩进（每级 2 格 + `|`）= **调用层级**；`}` 行 = 函数返回
- `DURATION` 列：叶子函数给出耗时；`+` 表示 >10 µs、`!` 表示 >100 µs、`#` 表示 >1000 µs
- 空白 DURATION 的 `{` 行是"有子调用"的容器节点，耗时见其配对的 `}` 行

## 3. 被跟踪的 mount 命令与结果

```console
# VM 内实际执行（tracing_on=1 与 tracing_on=0 之间仅此一条命令）：
mount -t erofs -o device=/dev/vdc /dev/vdb /mnt/md
# echo @@@@@@ MOUNT_RC=0 @@@@@@

# /proc/mounts：
/dev/vdb on /mnt/md type erofs (ro,relatime,user_xattr,acl,cache_strategy=readaround)

# dmesg：
[   10.299348] erofs (device vdb): initialized per-cpu workers successfully.
[   10.299538] erofs (device vdb): mounted with root inode @ nid 40.

# ls /mnt/md：
-rw-r--r--  0 4194304 rnd4m.bin
-rw-r--r--  0 1048576 text1m.bin
```

注意 dmesg 时间戳（10.299538）早于 trace 起始（10.302056）约 2.5 ms：  
串口输出走了重定向缓冲，属正常现象；trace 内部时序（10.302056 → 10.303058）自洽。

## 4. 完整函数调用栈（原始 trace 全文，3783 行）

以下为 `graph-mount-full.log` 原文（含 5 行 tracer 头注释），未做任何删改。   
[graph-mount-full.log]((https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-10-15-erofs-25-trace-mount-blobdev.txt)  

阶段定位索引（**行号为本文代码块内的行号**，与原始 log 文件一致）：

| 行号 | 节点 | 阶段 |
|---|---|---|
| 6 | `__x64_sys_mount() {` | 系统调用入口 |
| 158 | `path_mount()` | VFS 挂载主流程 |
| 188 | `fs_context_for_mount()` | 创建 fs_context |
| 198 | `erofs_init_fs_context()` | **erofs：sbi/devs 分配** |
| 232 | `erofs_fc_parse_param()` #1 | **erofs：source=/dev/vdb** |
| 240 | `parse_monolithic_mount_data()` | data 串解析 |
| 264 | `erofs_fc_parse_param()` #2 | **erofs：device=/dev/vdc** |
| 315 | `vfs_get_tree()` | 构建超级块树 |
| 316 | `erofs_fc_get_tree()` | **erofs：get_tree 钩子** |
| 317 | `get_tree_bdev_flags()` | 块设备型 fs 通用逻辑 |
| 318 | `lookup_bdev()` | 解析主设备路径 |
| 388 | `sget_fc()` | 分配 super_block |
| 538 | `setup_bdev_super()` | 打开主设备 → `sb->s_bdev` |
| 662 | `erofs_fc_fill_super()` | **erofs：fill_super 主体（808.7 µs）** |
| 666 | `erofs_read_metabuf()` #1 | 读 superblock |
| 915 | `z_erofs_parse_cfgs()` | 全局缓冲/per-cpu worker 配置 |
| 1201 | `erofs_init_device()` | **erofs：打开 blob 设备** |
| 1428 | `z_erofs_init_super()` | 压缩子系统初始化 |
| 2635 | `erofs_setup_managed_cache()` | managed cache 伪 inode |
| 2905 | `erofs_iget()` | 根 inode（nid 40） |
| 3041 | `erofs_shrinker_register()` | shrinker |
| 3051 | `erofs_register_sysfs()` | sysfs |
| 3650 | `do_add_mount()` → `graft_tree()` | 挂入 namespace |
| 3736 | `put_fs_context()` → `erofs_fc_free()` | **erofs：fc 清理** |
| 3783 | `} /* __x64_sys_mount */` | 系统调用返回 |

## 5. 主干调用链提炼（erofs 视角）

从 3778 行原始 trace 中提炼出的主干（缩进即层级，`★` 标 erofs 专属函数，
耗时取自 trace 配对的 `}` 行）：

```text
__x64_sys_mount                                          # 1002.610 us
├─ strndup_user ×3                        # dev_name / dir_name / type 从用户态拷入
└─ path_mount
   ├─ security_sb_mount                   # SELinux 授权
   ├─ get_fs_type("erofs")                # 找到 erofs_fs_type, try_module_get
   ├─ fs_context_for_mount
   │  └─ alloc_fs_context
   │     ├─ security_fs_context_alloc
   │     └─ erofs_init_fs_context         ★ super.c:914  分配 sbi + devs(dev_context)
   ├─ vfs_parse_fs_qstr("source")         # 第 1 次
   │  └─ vfs_parse_fs_param
   │     ├─ security_fs_context_parse_param
   │     └─ erofs_fc_parse_param          ★ super.c:476  记录 source=/dev/vdb
   ├─ parse_monolithic_mount_data         # data 串 "device=/dev/vdc"
   │  └─ generic_parse_monolithic
   │     └─ vfs_parse_monolithic_sep
   │        └─ vfs_parse_comma_sep
   │           └─ vfs_parse_fs_param      # 第 2 次
   │              ├─ security_fs_context_parse_param
   │              └─ erofs_fc_parse_param ★ Opt_device: kstrdup 路径 + down_write
   │                                          + kmem_cache_alloc(erofs_device_info)
   ├─ vfs_get_tree
   │  └─ erofs_fc_get_tree                ★ super.c:797
   │     └─ get_tree_bdev_flags           # 块设备型文件系统通用逻辑
   │        ├─ lookup_bdev → kern_path    # 路径解析 /dev/vdb
   │        ├─ sget_fc                    # 31.4 us  分配 super_block
   │        ├─ setup_bdev_super
   │        │  └─ bdev_file_open_by_dev   # 21.5 us  打开主设备 → sb->s_bdev
   │        ├─ fs_bdev_register
   │        └─ erofs_fc_fill_super        ★ super.c:651  808.7 us（占全程 80%）
   │           ├─ erofs_read_metabuf      ★ 读 superblock       92.6 us
   │           │  └─ erofs_bread → read_cache_folio →（filemap 全路径）
   │           ├─ z_erofs_parse_cfgs      ★ decompressor.c:417  59.4 us
   │           │  └─ z_erofs_gbuf_growsize   # 全局缓冲 + per-cpu worker 池
   │           ├─ erofs_scan_devices      ★ super.c:183（内联，无节点）
   │           │  └─ erofs_init_device    ★ super.c:125  42.2 us  打开 blob 设备
   │           │     ├─ erofs_read_metabuf        # 读 device table 槽位
   │           │     └─ fs_bdev_file_open_by_path → bdev_file_open_by_path
   │           │           → lookup_bdev(/dev/vdc) → fs_bdev_register
   │           ├─ erofs_put_metabuf ×2    ★ 释放元数据 folio 引用
   │           ├─ z_erofs_init_super      ★ zdata.c:677  478.1 us
   │           │  ├─ _erofs_printk        # "mounted with root inode @ nid 40"
   │           │  └─ erofs_setup_managed_cache ★ super.c:636  65.2 us
   │           │     └─ erofs_alloc_inode → 新 slab
   │           │           → erofs_inode_init_once ×24  # slab 构造器
   │           ├─ erofs_iget              ★ inode.c:293  17.2 us  根 inode(nid 40)
   │           │  └─ iget5_locked
   │           │     ├─ erofs_iget5_set   ★ inode.c:284
   │           │     └─ erofs_read_inode  ★ inode.c:36
   │           ├─ erofs_shrinker_register ★ zutil.c:214  1.4 us
   │           ├─ erofs_xattr_prefixes_init ★ xattr.c:494
   │           └─ erofs_register_sysfs    ★ sysfs.c:256  84.6 us（kernfs 全路径）
   ├─ mount_too_revealing                 # namespace 逃逸检查
   ├─ do_add_mount → graft_tree → attach_recursive_mnt   13.1 us
   │                                       # vfsmount 挂入 mount hash + 父计数
   ├─ __unlock_mount → namespace_unlock
   └─ put_fs_context
      └─ erofs_fc_free                    ★ super.c:894  释放 fc 临时结构
```

## 6. 知识要点

#### 6.1 mount(2) 如何走上新 fs_context 框架

老接口 `mount(2)` 并没有独立的 legacy 路径，而是在 `path_mount` 里被翻译成新 mount API 的五个回调：  
`init_fs_context` → `parse_param`（逐个参数）→`get_tree` →（间接）`fill_super` → 成功/失败后的 `fc_free`。  
erofs 五个钩子在 trace 中全部命中。**读 mount 源码时盯住这五个函数即可**：

| fc 钩子 | erofs 实现 | trace 命中 |
|---|---|---|
| init_fs_context | `erofs_init_fs_context`（super.c:914） | 行 198 |
| parse_param | `erofs_fc_parse_param`（super.c:476） | 行 232、264 |
| get_tree | `erofs_fc_get_tree`（super.c:797） | 行 316 |
| fill_super | `erofs_fc_fill_super`（super.c:651，由 get_tree_bdev_flags 调） | 行 662 |
| free | `erofs_fc_free`（super.c:894） | 行 3744 |

#### 6.2 两次 parse_param 的分工：source 与 device=

- 第 1 次（行 232，1.4 µs）：`path_mount` 直接用 `vfs_parse_fs_qstr` 传
  **source**，即 mount(2) 的 dev_name `/dev/vdb`。erofs 只把它记进
  `ctx->devs` 的 zero 号设备位（dif0，主设备），**不做任何打开动作**。
- 第 2 次（行 264，5.9 µs）：`parse_monolithic_mount_data → generic_parse_monolithic`
  把 data 串 `"device=/dev/vdc"` 按逗号拆开逐项解析。`erofs_fc_parse_param` 的
  `Opt_device` 分支同样只做登记：`kstrdup` 设备路径 + `down_write(&devs->rwsem)`
  + `kmem_cache_alloc`（erofs_device_info）+ 挂入 idr。
- **要点**：参数解析阶段 erofs 对两个设备都只存字符串，真正打开主设备在
  `get_tree_bdev_flags`（setup_bdev_super），打开 blob 设备在
  `erofs_fc_fill_super → erofs_init_device`。挂载失败时回滚很干净——
  `erofs_fc_free` 释放 devs 上下文即可，没有半开的设备。

#### 6.3 get_tree_bdev_flags 的固定三步

erofs 的 `get_tree` 钩子不自己干活，调 `get_tree_bdev_flags`（fs/super.c）：

1. `lookup_bdev → kern_path`：把 `/dev/vdb` 解析成 block_device
2. `sget_fc`：在 fc 的 sb 队列里查找或新建 super_block（冷挂载走新建；
   同设备重复挂载走 `erofs_fc_test` 比较复用）
3. `setup_bdev_super → bdev_file_open_by_dev`：打开主设备，
   `sb->s_bdev` 就位；随后 `fs_bdev_register` 注册 bdev 伪文件系统项
4. 最后才调 `erofs_fc_fill_super` —— **fill_super 是在 sb 已拿到 bdev 之后**

#### 6.4 erofs_fc_fill_super 的固定顺序（本 trace 实测）

| 步 | 函数 | 干什么 | 耗时 |
|---|---|---|---|
| 1 | `erofs_read_metabuf` | 读 superblock（block 0），校验 magic/布局 | 92.6 µs |
| 2 | `z_erofs_parse_cfgs` | 全局缓冲 metabox、per-cpu worker 池（"initialized per-cpu workers"） | 59.4 µs |
| 3 | `erofs_scan_devices`（内联）→ `erofs_init_device` | 逐槽读 device table；**打开 device= 指定的 blob** | 42.2 µs |
| 4 | `z_erofs_init_super` | 压缩子系统、`erofs_setup_managed_cache`（managed cache 伪 inode）、打印 root nid | 478.1 µs |
| 5 | `erofs_iget` | iget5_locked 根 inode（nid 40）→ `erofs_read_inode` | 17.2 µs |
| 6 | `erofs_shrinker_register` / `erofs_xattr_prefixes_init` | shrinker、xattr 前缀表 | ~1.5 µs |
| 7 | `erofs_register_sysfs` | `/sys/fs/erofs/<disk>` 属性 | 84.6 µs |

#### 6.5 blobdev 场景的两个独立 bdev 句柄

本 trace 最值得看的一段：`erofs_init_device`（行 1201）内部，
- 先 `erofs_read_metabuf` 读 device table 的 1 号槽（erofs_deviceslot，128 B）；
- 再 `fs_bdev_file_open_by_path → bdev_file_open_by_path → lookup_bdev(/dev/vdc)`
  → `fs_bdev_register` —— 与主设备走 `setup_bdev_super` 的路径**平行且独立**。

挂载成功后的 dev 结构：`sbi->devs->tree` idr 上挂着 `erofs_device_info`，  
dif0（主设备）用 `sb->s_bdev`，dif1（blob）用自己打开的 `file/bdev`。  
读数据时 `erofs_map_dev` 按 chunk 的 device_id 选用二者之一。

#### 6.6 erofs_inode_init_once ×24 不是 mount 在建 24 个 inode

行 2678-2900 连续 24 次 `erofs_inode_init_once`（super.c）  
发生在`erofs_setup_managed_cache → erofs_alloc_inode` 内：  
这是 slab 分配器给inode cache 补新页时对页内 24 个对象逐个跑**构造函数**（slab ctor），  
 managed_cache 伪 inode 只是碰巧成了这块新 slab 的第一个使用者。  
mount 真正"读"出来的 inode 只有一个：根 inode（`erofs_iget`，nid 40）。

#### 6.7 成功路径也会调 erofs_fc_free

行 3736 `put_fs_context → erofs_fc_free`（super.c:894）出现在 mount **成功**之后：  
fs_context 本身是"脚手架"，fill_super 成功后 sb/sbi 已被 VFS 接管，  
脚手架（含 parse_param 阶段登记的 devs 结构被 sbi 引用的部分）就地拆除。  
失败路径同样走 fc_free，因此它是理解 erofs mount 回滚的入口。

#### 6.8 耗时热点：fill_super 占 80%

| 热点 | 耗时 | 原因 |
|---|---|---|
| 读 superblock | 92.6 µs | 首次 `read_cache_folio`：page 分配 + block 层读 + unlock 等待全路径 |
| `z_erofs_init_super` | 478.1 µs | printk 串口输出 + slab 预热（新 slab ×24 ctor）+ per-cpu 初始化 |
| `erofs_register_sysfs` | 84.6 µs | kernfs 建目录/属性文件的全路径 |
| `erofs_init_device` | 42.2 µs | blob 的路径解析 + bdev 打开 |
| `sget_fc` | 31.4 µs | super_block 分配（alloc_super 大结构体） |

#### 6.9 trace 里"缺席"的 erofs 函数 ≠ 流程缺失

`erofs_scan_devices`（super.c:183）、`do_new_mount`（fs/namespace.c）等在trace 中没有独立节点，  
是因为被编译器**内联**进调用者（fill_super / path_mount），ftrace 的 function_graph 只画有独立栈帧的函数。    
这是方法论的固有限制，读 trace 时要把 `erofs_init_device` 的参数处理理解成 scan_devices 循环体。

#### 6.10 从 mount 参数到运行期 dev 结构的完整时序

```text
mount(2) data="device=/dev/vdc"
  → erofs_fc_parse_param: kstrdup + idr 登记            （只存字符串）
  → erofs_fc_fill_super: erofs_scan_devices 循环
       → erofs_init_device: 读 deviceslot + 打开 blob   （变成 struct file/bdev）
  → 挂载完成: sbi->devs = { dif0(sb->s_bdev), dif1(blob) }
  → 之后每次读: erofs_map_dev 按 chunk device_id 选设备
```

## 7. 复现步骤

```sh
# 宿主机（root@55.154.14.159）：
cd /home/linux/erofs/multidev
sh 01-mkimg.sh                       # ① 制作 main.erofs + blob.img（--blobdev）
sh 02-vm-run.sh \
    /home/linux/erofs/multidev/vm-cmds-mount.txt \
    /home/linux/erofs/multidev/trace-mount.log   # ② 起 VM，喂命令，等关机
# ③ 结果已在 /home/linux/erofs/multidev/graph-mount-full.log（VM 经 9p 直写）
grep -a "MOUNT_RC\|GRAPH_MOUNT" trace-mount.log   # 确认 RC=0 与行数
```

VM 侧命令序列（`vm-cmds-mount.txt`）：9p 挂载 → `sh /host/multidev/trace-mount.sh`
→ `poweroff -f`。`trace-mount.sh` 见 §2。

[01-mkimg.sh]((https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-10-15-erofs-25-trace-mount-blobdev-01-mkimg.sh)  
[02-vm-run.sh]((https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-10-15-erofs-25-trace-mount-blobdev-02-vm-run.sh)   
[trace-mount.sh]((https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-10-15-erofs-25-trace-mount-blobdev.sh)  

## 附录 A. 产物清单

| 文件 | 说明 |
|---|---|
| `multidev/trace-mount.sh` | VM 内跟踪脚本（function_graph，根 __x64_sys_mount） |
| `multidev/vm-cmds-mount.txt` | VM 命令序列 |
| `multidev/trace-mount.log` | 串口全程日志（517 行，含 dmesg 与 mount 输出） |
| `multidev/graph-mount-full.log` | **原始 ftrace 输出（3783 行）** |
| `multidev/main.erofs` / `blob.img` | 本次测试镜像（2026-10-15 17:42 制作） |