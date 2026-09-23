---
layout:     post
title:      EROFS trace dedupe ishare reading-path
subtitle:   EROFS 跟踪 dedupe 与 ishare 读路径
date:       2026-09-23
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
  - fs
  - erofs
  - ai
---

# EROFS dedupe 与 ishare 读路径实测

15 专题讲 dedupe 时有个说法不太好验证：**「跨文件重复只存一份，其余位置记为引用」**。
光看代码只能看到 `Z_EROFS_LI_PARTIAL_REF` 这个标志位和 `partial_decoding` 这个开关，
但「引用」到底长什么样、读起来有什么不同，得实测。

而 11 专题的 ishare（page cache sharing）又常常和 dedupe 混在一起谈。
两者都跟「重复数据」有关，但**共享的东西根本不是一个层次**——
这一篇用同一套 ftrace 手法把两者摆在一起对比。

**只用两个镜像**就能覆盖全部四项测试：

| 测试 | 目的 | 用到的镜像 |
|---|---|---|
| **A** | 基线：只压缩、不开 dedupe | `plain.erofs` |
| **B** | 开了 dedupe，冷读 | `dedupe.erofs` |
| **C** | 读 a 之后再读 b —— dedupe 共享数据会加速吗？ | `dedupe.erofs` |
| **D** | ishare：两个镜像里的相同文件共享页缓存吗？ | `plain.erofs` + `dedupe.erofs` |

## 结论速览

| 段 | 场景 | trace 行数 | 去噪后 | `erofs_bread` |
|---|---|---|---|---|
| A | plain 冷读 b.bin | 7023 | 600 | 7 |
| B | dedupe 冷读 b.bin | 6934 | 600 | 7 |
| C1 | dedupe 读 a.bin（冷读） | 6968 | 600 | 7 |
| **C2** | dedupe 紧接着读 b.bin | **6885** | **610** | **7** |
| C3 | dedupe 再读一次 b.bin | 328 | **11** | 0 |
| D1 | ishare 同 domain，冷读 a | 3151 | 256 | 7 |
| **D2** | ishare 同 domain，紧接着读 b | **328** | **11** | **0** |
| D3 | ishare 不同 domain，冷读 a | 3147 | 256 | 7 |
| **D4** | ishare 不同 domain，紧接着读 b | **3140** | **256** | **7** |

三个反直觉的结论：

1. **C2 不命中**（6885 行）—— a 和 b 在磁盘上共享同一份数据，
   但读 a 之后读 b 仍要走完整路径。**dedupe 共享的是磁盘块，不是页缓存。**
2. **C3 才命中**（328 行）—— 那是「同一个文件连续读两次」的页缓存命中，
   和 dedupe 没关系。
3. **D2 命中**（328 行）—— 这才是**跨文件**共享页缓存，靠的是 ishare，
   而且需要**同一 `domain_id`**。

## 0. 环境 / 前提

| 项 | 值 |
|---|---|
| 宿主机内核 | `5.10.0`（本机，**不是**被测内核，别混） |
| VM 内核 | `/home/linux/erofs/linux-stable`，`v7.3-rc3-60-g587858367581` |
| initrd / rootfs | `/home/linux/erofs/erofs-boot-initrd.img`、`erofs-rootfs-ext4.img` |
| 被测镜像 | 打包进 rootfs 的 `/images/{plain,dedupe}.erofs` |
| 9p 共享 | `-virtfs local,path=/home/linux/erofs,mount_tag=host` ⇒ VM 内 `/host` |
| mkfs | `/opt/erofs-utils/bin/mkfs.erofs` 1.9.4 |
| 内核配置 | `CONFIG_EROFS_FS_PAGE_CACHE_SHARE=y`（ishare 需要） |

## 1. 造两个镜像（覆盖 A/B/C/D 四项测试）

**只造两个镜像**，四项测试全部复用：

| 镜像 | mkfs 选项 | 服务于 |
|---|---|---|
| `plain.erofs` | `-zlz4` | **A**（不开 dedupe 的基线）+ **D**（提供 shared.bin） |
| `dedupe.erofs` | `-zlz4 -Ededupe` | **B / C**（去重）+ **D**（提供 shared.bin） |

两个镜像都带 `--xattr-inode-digest`（D 实验的 ishare 需要它），
也都含**同一份内容**的 `shared.bin` —— 这就是 D 实验的共享对象。

```bash
cd /home/linux/erofs/dedupe
# 512B 随机块 × 8192 的 payload（重复粒度落在 pcluster 内部 ⇒ 压得动）
head -c 512 /dev/urandom > /tmp/u512a.bin
head -c 512 /dev/urandom > /tmp/u512b.bin
: > /tmp/payload_shared.bin ; : > /tmp/payload_dup.bin
i=1; while [ $i -le 8192 ]; do
	cat /tmp/u512a.bin >> /tmp/payload_shared.bin
	cat /tmp/u512b.bin >> /tmp/payload_dup.bin
	i=$((i+1))
done

# plain：shared.bin（与 dedupe 相同）+ b.bin
cp /tmp/payload_shared.bin src_plain/shared.bin
( cat /tmp/payload_dup.bin; head -c 512 /dev/zero ) > src_plain/b.bin

# dedupe：shared.bin（同内容）+ a/b/c（a 与 b/c 共享数据）
cp /tmp/payload_shared.bin src_dedupe/shared.bin
cat /tmp/payload_dup.bin > src_dedupe/a.bin
( cat /tmp/payload_dup.bin; head -c 512  /dev/zero ) > src_dedupe/b.bin
( cat /tmp/payload_dup.bin; head -c 4096 /dev/zero ) > src_dedupe/c.bin

mkfs.erofs -b4096 -zlz4          --xattr-inode-digest plain.erofs  src_plain
mkfs.erofs -b4096 -zlz4 -Ededupe --xattr-inode-digest dedupe.erofs src_dedupe
```

#### 坑一：数据必须可压缩，否则 dedupe 根本不参与

第一版我用纯随机数据，`deduplicated bytes` 一直是 **0**。原因是压不动
→ 文件存为 **Layout 0（flat plain，未压缩）**，压根不进压缩路径，dedupe 无从下手。

#### 坑二：重复粒度要落在压缩单元（pcluster）内部

第二版用「4KB 块重复」，仍压不动 —— 因为 EROFS 压缩以 **pcluster** 为单元，
4KB 块重复意味着**每个压缩单元内部**仍是随机数据。
改成 **512B 重复**后，每个 4KB 单元内含 8 次重复，lz4 才压得动（`0.49%`）。

⇒ 两个镜像这才都走压缩路径，A 与 B 的对照才纯粹。

#### 验证

```
=== incompat 特性位 ===
  plain    :  lz4_0padding xattr_prefixes
  dedupe   :  lz4_0padding fragments dedupe xattr_prefixes
              （dedupe 与 fragments 都是 0x20 —— 位别名，两个名字会一起出现）

=== dedupe 镜像里 a/b/c 指向同一段 ===
  a.bin : 0: 0..911360 | 911360 : 4096..8192 | 4096
  b.bin : 0: 0..911360 | 911360 : 4096..8192 | 4096      ← 完全相同
  c.bin : 0: 0..911360 | 911360 : 4096..8192 | 4096

=== 两个镜像都含 shared.bin（D 实验用）===
  plain    : Size: 4194304  On-disk size: 20480
  dedupe   : Size: 4194304  On-disk size: 4096
```

镜像大小：**plain 49152 B / dedupe 57344 B**，`deduplicated bytes: 73728`。

## 2. 把镜像打包进 ext4 rootfs

```bash
cd /home/linux/erofs
mount -o loop /home/linux/erofs/erofs-rootfs-ext4.img /mnt/ext4root
mkdir -p /mnt/ext4root/images
cp /home/linux/erofs/dedupe/{plain,dedupe}.erofs /home/linux/erofs/dedupe/src.md5 /mnt/ext4root/images/
umount /mnt/ext4root          # ★ 不卸载 QEMU 会报 Failed to get write lock
```

跑之前确认环境干净：`pgrep -c qemu-system`、`mount | grep erofs-rootfs` 都应为 0。

## 3. 起 VM

镜像已经在 rootfs 里，所以**只要一块盘**；9p 保留（trace 要写回宿主机）：

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

## 4. VM 内：三阶段挂载 + 校验 + ftrace

脚本 `trace-all.sh` 把九段串起来，挂载分**三个阶段**
（每个镜像同时只挂一次 —— 同一文件挂两次会撞 loop）：

| 阶段 | 挂载方式 | 段 |
|---|---|---|
| 1 | 普通挂载 | A / B / C1 / C2 / C3 |
| 2 | `domain_id=demo` + `inode_share` | D1 / D2 |
| 3 | `domain_id=demoA` / `demoB` + `inode_share` | D3 / D4 |

```sh
mkdir -p /host
mount -t 9p -o trans=virtio,version=9p2000.L host /host
for i in 0 1 2 3; do ls /dev/loop$i >/dev/null 2>&1 || mknod /dev/loop$i b 7 $i; done

# 阶段 1
mount -t erofs /images/plain.erofs  /mnt/plain
mount -t erofs /images/dedupe.erofs /mnt/dedupe
```

**先做正确性校验**——dedupe 只存一份，读出来必须和源文件一模一样：

```sh
cut -d" " -f1 /images/src.md5 > /tmp/want
md5sum /mnt/dedupe/a.bin /mnt/dedupe/b.bin /mnt/dedupe/c.bin | cut -d" " -f1 > /tmp/got
diff -q /tmp/want /tmp/got && echo "MD5_dedupe=OK"
```

实测 **`MD5_dedupe=OK`** ✔ —— 去重没有改变语义。

ftrace 配置（根函数必须是 `__x64_sys_read`，`vfs_read` 那类被内联、0 命中）：

```sh
cd /sys/kernel/tracing
echo nop > current_tracer
echo 512 > buffer_size_kb
echo function_graph > current_tracer
echo __x64_sys_read >> set_graph_function
echo 0 > options/funcgraph-irqs
echo 1 > options/funcgraph-abstime
# set_graph_notrace：锁 / 调度 / tty / RCU …（完整列表见 trace-all.sh）
```

每次抓取的固定套路（关键在**要不要 drop_caches**）：

```sh
[ 冷读 ] echo 3 > /proc/sys/vm/drop_caches
echo > trace
echo 1 > tracing_on
dd if=<文件> of=/dev/null bs=4096 count=8
echo 0 > tracing_on
cat trace > /host/dedupe/graph-<段>.log        # ★ 写 9p，别 cat 到串口
```

## 5. A / B / C 三段实验

[graph-A_PLAIN.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-graph-A_PLAIN.log)

[graph-B_DEDUPE.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-graph-B_DEDUPE.log)

| 段 | 镜像 | 怎么读 | 目的 |
|---|---|---|---|
| A | plain | 冷读 b.bin（drop cache） | 基线：只压缩、不开 dedupe |
| B | dedupe | 冷读 b.bin（drop cache） | 基线：开了 dedupe |
| C1 | dedupe | 冷读 a.bin | 读 a 的完整调用链 |
| C2 | dedupe | 紧接着读 b.bin（**不** drop） | a 之后读 b —— 会命中吗？ |
| C3 | dedupe | 再读一次 b.bin（**不** drop） | 对照组：同一文件连读 |

```
段                    行数   去噪   bread  scan_folio  map_iter
A_PLAIN               7023   600     7        84         3
B_DEDUPE              6934   600     7        84         3
C1_READ_A             6968   600     7        84         3
C2_READ_B_AFTER_A     6885   610     7        84         3      ← a 之后读 b：仍然完整！
C3_SAME_FILE           328    11     0         0         0      ← 同一文件再读：命中
```

## 6. C 项的两次读：调用链对比

#### 6.1 读 a.bin（C1，冷读）—— 完整的 EROFS 压缩读路径

[graph-C1_READ_A.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-graph-C1_READ_A.log)

```
erofs_file_read_iter() {
  z_erofs_readahead() {
    erofs_real_inode();
    z_erofs_pcluster_readmore() {
      z_erofs_map_blocks_iter() {
        erofs_read_metabuf() { erofs_bread() { ... } }      ← 读元数据
        z_erofs_map_blocks_fo() {
          z_erofs_load_lcluster_from_disk() {
            erofs_read_metabuf() { erofs_bread() { ... } }
          }
        }
        erofs_unmap_metabuf();
      }
    }
    z_erofs_scan_folio() {                                  ← 逐个 folio 处理
      erofs_onlinefolio_init();
      erofs_onlinefolio_split();
      erofs_onlinefolio_end();
    }
    ...（重复 N 次）
```

去噪后 **600 行**，`erofs_bread` 7 次、`z_erofs_scan_folio` 84 次。

#### 6.2 之后读 b.bin（C2，不 drop cache）—— **还是完整路径**

[graph-C2_READ_B_AFTER_A.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-graph-C2_READ_B_AFTER_A.log)

去噪后 **610 行**（比 C1 还多一点），`erofs_bread` 仍 7 次、`scan_folio` 仍 84 次。

**关键结论**：读 a **并没有**让读 b 变快。

虽然 a 和 b 在**磁盘上**共享同一份数据（dedupe 的直接效果），
但 **Linux 的 page cache 是按 `(inode, offset)` 索引的** ——
a 和 b 是两个不同的 inode，各自的 `address_space` 互不相通。
读 a 把数据缓存到了 a 的地址空间，读 b 时在 b 的地址空间里找不到，只能老老实实再走一遍。

⇒ **dedupe 共享的是磁盘块，不是页缓存。**

#### 6.3 再读一次 b.bin（C3）—— 这才命中
[graph-C3_SAME_FILE.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-graph-C3_SAME_FILE.log)
```
erofs_file_read_iter() {      × 8（每个 4KB 一次）
```

去噪后只剩 **11 行**，`erofs_bread` 0 次 —— 数据全在页缓存里。

⇒ 缓存命中是「**同一个文件被连续读**」带来的，**和 dedupe 没有关系**。

| 问题 | 答案 |
|---|---|
| dedupe 省磁盘空间吗？ | **省**（a/b/c extent 指向同一段） |
| dedupe 让读同一个文件更快吗？ | 不，同文件快是 page cache 的功劳 |
| dedupe 让读**共享数据的另一个文件**更快吗？ | **不** —— page cache 按 inode 索引，不共享 |
| 那想让不同文件共享页缓存怎么办？ | 用 **ishare**，见 §7 |

## 7. D 实验：ishare（page cache sharing）

§6 的结论是「dedupe 共享磁盘块、**不**共享页缓存」。那**谁能**让不同文件共享页缓存？
—— 这是 **11 专题 ishare** 的活。这一节用实测验证。

#### 7.1 镜像：直接复用 §1 的那两个

**不需要另造镜像** —— §1 造 `plain.erofs` / `dedupe.erofs` 时已经：

- 给两个镜像都加了 `--xattr-inode-digest`（ishare 靠它认出「内容相同」）
- 都放了**同一份内容**的 `shared.bin`

所以 D 实验直接用这两个镜像的 `shared.bin` 即可。
（dump 里能看到 `Xattr size: 104`，那就是 digest。）

#### 7.2 挂载：domain_id + inode_share

```sh
# 同一 domain_id ⇒ 共享
mount -t erofs -o domain_id=demo,inode_share /images/plain.erofs  /mnt/plain
mount -t erofs -o domain_id=demo,inode_share /images/dedupe.erofs /mnt/dedupe

# 不同 domain_id ⇒ 不共享（对照组）
mount -t erofs -o domain_id=demoA,inode_share /images/plain.erofs  /mnt/plain
mount -t erofs -o domain_id=demoB,inode_share /images/dedupe.erofs /mnt/dedupe
```

挂上后内核会打印一行提醒（实验性特性）：

```
erofs (device loop0): EXPERIMENTAL EROFS page cache share support in use. Use at your own risk!
```

⚠️ **踩坑**：同一个镜像文件**不能同时挂两次** —— busybox 会复用同一个 loop 设备，
第二次报 `Device or resource busy` 与 `would change RO state`。
所以三组挂载（A/B/C 组、D 同 domain 组、D 不同 domain 组）是**先后进行**的：
每组测完 `umount`，再挂下一组。

#### 7.3 四段与结果

| 段 | 挂载 | 怎么读 | 行数 | 去噪 | `erofs_bread` |
|---|---|---|---|---|---|
| D1 | 同 domain | 冷读 plain/shared.bin | 3151 | 256 | 7 |
| **D2** | 同 domain | 紧接着读 **dedupe**/shared.bin | **328** | **11** | **0** |
| D3 | 不同 domain | 冷读 plain/shared.bin | 3147 | 256 | 7 |
| **D4** | 不同 domain | 紧接着读 **dedupe**/shared.bin | **3140** | **256** | **7** |

⇒ **D2 命中（328 行）、D4 不命中（3140 行）** —— 差别只在 `domain_id`。

#### 7.4 调用栈对比

[graph-D1_ISHARE_A.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-graph-D1_ISHARE_A.log)

**D1：读 plain/shared.bin（冷读）—— 完整的 ishare 读路径**

```
erofs_ishare_file_read_iter() {          ← ★ ishare 的读入口
  z_erofs_readahead() {
    erofs_real_inode();
    z_erofs_pcluster_readmore() {
      z_erofs_map_blocks_iter() {
        erofs_read_metabuf() { erofs_bread() { ... } }      ← 读元数据
        z_erofs_map_blocks_fo() {
          z_erofs_load_lcluster_from_disk() {
            erofs_read_metabuf() { erofs_bread() { ... } }
          }
        }
        erofs_unmap_metabuf();
      }
    }
    z_erofs_scan_folio() { ... }          ← 逐个 folio 解压填充
    z_erofs_pcluster_end();
  }
}
```

**D2：之后读 dedupe/shared.bin（同 domain）—— 只剩 ishare 入口**

[graph-D2_ISHARE_B.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-graph-D2_ISHARE_B.log)

```
erofs_ishare_file_read_iter() {     × 8
```

**一行 EROFS 内部函数都没有** —— 数据在页缓存里直接命中，
连 `z_erofs_readahead` 都没进。

**D4：之后读 dedupe/shared.bin（不同 domain）—— 和 D1 一样完整**

[graph-D3_DIFFDOMAIN_A.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-graph-D3_DIFFDOMAIN_A.log)

[graph-D4_DIFFDOMAIN_B.log](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-graph-D4_DIFFDOMAIN_B.log）

```
erofs_ishare_file_read_iter() {
  z_erofs_readahead() { ... }            ← 完整走一遍
}
```

### 7.5 与 §6 的呼应

| 机制 | 共享什么 | 证据 |
|---|---|---|
| **dedupe** | 磁盘块 | a/b 的 extent 指向同一段；但读 a 后读 b 仍完整走一遍（C2 6885 行） |
| **ishare** | **页缓存** | 同 domain 下读 b 只剩 `erofs_ishare_file_read_iter` × 8（D2 328 行） |

⇒ 两者解决的是**不同层次**的问题：

- **dedupe 省存储** —— mkfs 时决定，内核只是照读
- **ishare 省内存与 IO** —— 运行时把内容相同的文件的页缓存合并

**识别特征**：挂了 `inode_share` 之后，读入口从 `erofs_file_read_iter()`
变成 **`erofs_ishare_file_read_iter()`** —— 这是 ishare 生效最直接的表征
（不带 ishare 的 C3 段里没有这个函数）。

## 8. 去噪：只留 EROFS 内部调用图

```bash
sh 04-erofs-only.sh                                # 处理九段
sh 04-erofs-only.sh graph-C1_READ_A.log out.txt    # 或只处理一个
```

核心就一句（保留缩进 = 调用层级）：

```sh
awk -F"|" "{print \$NF}" graph-X.log | grep -aE "erofs_|z_erofs_"
```

| 段 | 原 | 去噪后 |
|---|---|---|
| A_PLAIN | 7023 | 600 |
| B_DEDUPE | 6934 | 600 |
| C1_READ_A | 6968 | 600 |
| C2_READ_B_AFTER_A | 6885 | 610 |
| C3_SAME_FILE | 328 | **11** |
| D1_ISHARE_A | 3151 | 256 |
| D2_ISHARE_B | 328 | **11** |
| D3_DIFFDOMAIN_A | 3147 | 256 |
| D4_DIFFDOMAIN_B | 3140 | 256 |

（在 ftrace 里直接过滤做不到这么干净：把 graph 根设成 EROFS 入口后，
展开时 erofs 调用的 VFS 函数照样被带出来。宿主机侧后处理才是干净的做法。）

## 9. 注意事项

1. **数据必须可压缩** —— 纯随机数据存为未压缩，dedupe 字节数为 0
2. **重复粒度要落在压缩单元内部** —— 4KB 块重复压不动（pcluster 内是随机的），512B 才行
3. **共同部分放前面** —— 前缀会让整段 payload 错位，块对不齐就匹配不上
4. **ishare 需要 mkfs 写 inode digest**（`--xattr-inode-digest`），否则两个镜像里的「相同文件」认不出来
5. **同一个镜像文件不能同时挂两次**：busybox 会复用同一个 loop 设备，  
   第二次报 `Device or resource busy` / `would change RO state` ——  
   要对照就换 `domain_id`，或者先后挂载（先测完 umount 再挂）
6. 根函数用 `__x64_sys_read`，别用 `vfs_read` / `ksys_read` / `do_mount`
7. trace 写 9p，**别 `cat` 到串口**
8. VM 的 `/dev` 只有 loop0，多个镜像同时挂要 `mknod /dev/loopN b 7 N`
9. 改完 rootfs 必须 `umount`，否则 QEMU 拿不到写锁
10. `mkfs` 会打印 `multi-threaded dedupe is NOT implemented for now`，  
    只是告警 —— 实测 dedupe **仍然生效**（看 `deduplicated bytes` 有没有值）
11. `-Ededupe` 需要压缩已启用（`-zlz4`），否则 mkfs 会建议你改用 chunk-based 去重

## 10. 跟踪脚本

[trace shell script](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-09-23-erofs-trace-all.sh)