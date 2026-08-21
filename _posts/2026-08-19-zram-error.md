---
layout:     post
title:      Zram Can't change algorithm for initialized device
subtitle:   zram切换算法失败问题
date:       2026-08-19
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - misc
---

# 问题

**zram: Can't change algorithm for initialized device**

### 原因

这不是 kernel 的 bug，而是用户态（init 脚本）写 `/sys/block/zram0/comp_algorithm` 的**顺序错误**。

在 `drivers/block/zram/zram_drv.c` 中，`__comp_algorithm_store()` 会先检查设备是否已初始化：

```c
down_write(&zram->init_lock);
if (init_done(zram)) {
    up_write(&zram->init_lock);
    kfree(compressor);
    pr_info("Can't change algorithm for initialized device\n");
    return -EBUSY;
}
```

`init_done(zram)` 的判断依据是 `zram->disksize != 0`（即 `disksize` 已被写入）。  
一旦 `disksize` 被设置，zram 设备即视为已初始化，此时再修改压缩算法会被拒绝，返回 `-EBUSY`。

### 正确配置顺序

**必须先设算法，再设大小：**

```sh
echo lz4 > /sys/block/zram0/comp_algorithm
echo 2G  > /sys/block/zram0/disksize
mkswap /dev/zram0 && swapon /dev/zram0
```

### 排查方向

1. 查找 init 拉起的初始化脚本/服务里对 zram 的操作，确认是否先写了 `disksize`。  
常见于 init.rc / fstab 中配置了 zram swap（`/dev/block/zram0 none swap defaults zramsize=...`）,  
init 早已把 disksize 设好，之后某脚本再去写 `comp_algorithm`。

2. 若需重置算法，须先复位设备：

   ```sh
   swapoff /dev/zram0
   echo 1 > /sys/block/zram0/reset
   echo lz4 > /sys/block/zram0/comp_algorithm
   echo 2G > /sys/block/zram0/disksize
   ```

3. 也可通过模块参数 `zram.num_devices` 或内核配置 `CONFIG_ZRAM_DEF_COMP` 指定默认算法，避免运行时修改。


```
ubuntu:/$ echo 1 > /sys/block/zram0/reset
ubuntu:/$
ubuntu:/$ echo 2G > /sys/block/zram0/disksize
[  288.922067] zram0: detected capacity change from 0 to 4194304
ubuntu:/$ echo lz4 > /sys/block/zram0/comp_algorithm
[  293.753110] zram: Can't change algorithm for initialized device
ash: write error: Device or resource busy
ubuntu:/$
ubuntu:/$ echo 1 > /sys/block/zram0/reset
[ 1021.697766] zram0: detected capacity change from 4194304 to 0
ubuntu:/$ echo lz4 > /sys/block/zram0/comp_algorithm
ubuntu:/$ echo 2G > /sys/block/zram0/disksize
[ 1031.862450] zram0: detected capacity change from 0 to 4194304
ubuntu:/$
```

## 参考  
[linux-6.6](https://elixir.bootlin.com/linux/v6.6/source)
