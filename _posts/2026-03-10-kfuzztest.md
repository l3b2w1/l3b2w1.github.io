---
layout:     post
title:      kfuzztest introduction
subtitle:   kfuzztest 原理与实践
date:       2026-03-10
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - debug
---
# 功能简介

KFuzzTest的主要是简化对低级、相对无状态函数（如数据解析器、格式转换器）的模糊测试，这些函数很难通过系统调用边界有效覆盖。

从系统调用边界作为入口时，会存在一些代码路径比较难以执行到，但是利用kfuzztest可以覆盖这些路径。

支持直接在内核环境中进行模糊测试，无需将代码构建为单独的用户空间库或模拟其依赖项。

开发者只需使用基于宏的简单API，就能以最简模板代码添加新的模糊测试目标。

### 执行流程

| 步骤 | 执行位置 | 操作内容 | 通信方式 |
|------|----------|----------|----------|
| 1 | 内核开发 | 在内核代码中使用FUZZ_TEST定义目标 | 无 |
| 2 | 用户态 | 编写DSL输入描述，准备随机数据 | 无 |
| 3 | 用户态 | kfuzztest-bridge解析DSL生成AST | 无 |
| 4 | 用户态 | 编码为KFuzzTest二进制格式 | 无 |
| 5 | 用户态→内核态 | write()到debugfs /input文件 | 系统调用 |
| 6 | 内核态 | copy_from_user到内核缓冲区 | 内存拷贝 |
| 7 | 内核态 | 解析头部、区域数组、重定位表 | 内核内存 |
| 8 | 内核态 | 指针重定位和内存毒化 | 内核内存 |
| 9 | 内核态 | 调用静态测试函数 | 函数调用 |
| 10 | 内核态 | 执行目标内核函数 | 函数调用 |
| 11 | 内核态 | 检测错误(KASAN/panic) | 内核机制 |
| 12 | 内核态→用户态 | 通过系统日志反馈结果 | dmesg/日志 |

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-03-10-kfuzztest-flow.png)

# 组织结构

从代码上来说包含内核态和用户态两个部分，以及针对描述文本定义的规则

### 内核态组件

a. API 头文件(include/linux/kfuzztest.h)：主要是FUZZ_TEST 宏和约束/注解宏

b. lib/kfuzztest：处理模块初始化、debugfs 接口和输入解析

c. ELF 段支持：通过链接脚本添加 .kfuzztest_target 等section 段来存储元数据

### 用户空间工具

给用户使用的命令行工具kfuzztest-bridge

kfuzztest-bridge将文本描述和随机数据编码为 KFuzzTest 二进制格式

kfuzztest-bridge内部实现文本格式解析器：词法分析器 + 语法分析器，解析输入结构描述

二进制输入格式: 采用区域+重定位表的设计：

> [8字节头部][区域数组][重定位表][填充][载荷数据]

### 文本语法规则

```
schema ::= region ( ";" region )* [";"]
region ::= identifier "{" type+ "}"
type ::= primitive | pointer | array | length | string
primitive ::= "u8" | "u16" | "u32" | "u64"
pointer ::= "ptr" "[" identifier "]"
array ::= "arr" "[" primitive "," integer "]"
length ::= "len" "[" identifier "," primitive "]"
string ::= "str" "[" integer "]"
identifier ::= [a-zA-Z_][a-zA-Z1-9_]*
integer ::= [0-9]+
```

**数据类型说明**

1. 基本类型: u8, u16, u32, u64: 无符号整数

2. 指针类型: ptr[region_name]: 指向指定区域的指针

3. 数组类型: arr[type, size]: 固定大小的数组
   示例: arr[u8, 100] - 100字节的字节数组

4. 长度字段:
   len[region_name, type]: 自动设置为目标区域的大小
   示例: len[data, u64] - 64位整数，值为data区域大小

5. 字符串类型:
   str[size]: 以null结尾的字节数组
   等同于 arr[u8, size] + 自动null终止

### 系统目录结构

测试项目录结构如下

```
# tree /sys/kernel/debug/kfuzztest/
/sys/kernel/debug/kfuzztest/
|-- test_overflow_on_nested_buffer
|   `-- input
|-- test_pkcs7_parse_message
|   `-- input
|-- test_rsa_parse_priv_key
|   `-- input
|-- test_rsa_parse_pub_key
|   `-- input
`-- test_underflow_on_buffer
    `-- input
```

### 组件交互图

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-03-10-kfuzztest-interact.png)

# Kfuzztest-bridge

### 核心功能

> 1. 解析可读的字符串描述的输入结构， 把文本描述转换为二进制格式
> 2. 集成随机数据源，从文件/dev/urandom读取随机字节
> 3. 通过 debugfs 与内核通信，把编码后的数据发送到对应的 KFuzzTest 目标

基本命令格式如下：

```
kfuzztest-bridge <input-description> <fuzz-target-name> <input-file>
```

参数说明

| 参数 | 说明 |
|------|------|
| input-description | 文本格式的输入结构描述 |
| fuzz-target-name | 内核中注册的 KFuzzTest 目标名称 |
| input-file | 随机数据源文件路径（如 `/dev/urandom`） |

### 开发示例

> **rsa_parse_priv_key / rsa_parse_pub_key 是crypto模块常用的函数，**
> **以模糊测试这两个函数为例**

- 在crypto下添加内核态框架代码，使用导出的API 定义需要测试的类型，代码如下：

```
crypto/asymmetric_keys/tests/rsa_helper_kfuzz.c

struct rsa_parse_pub_key_arg {
    const void *key;
    size_t key_len;
};

FUZZ_TEST(test_rsa_parse_pub_key, struct rsa_parse_pub_key_arg)
{
    KFUZZTEST_EXPECT_NOT_NULL(rsa_parse_pub_key_arg, key);
    KFUZZTEST_ANNOTATE_LEN(rsa_parse_pub_key_arg, key_len, key);
    KFUZZTEST_EXPECT_LE(rsa_parse_pub_key_arg, key_len, 16 * PAGE_SIZE);

    struct rsa_key out;
    rsa_parse_pub_key(&out, arg->key, arg->key_len);
}

struct rsa_parse_priv_key_arg {
    const void *key;
    size_t key_len;
};

FUZZ_TEST(test_rsa_parse_priv_key, struct rsa_parse_priv_key_arg)
{
    KFUZZTEST_EXPECT_NOT_NULL(rsa_parse_priv_key_arg, key);
    KFUZZTEST_ANNOTATE_LEN(rsa_parse_priv_key_arg, key_len, key);
    KFUZZTEST_EXPECT_LE(rsa_parse_priv_key_arg, key_len, 16 * PAGE_SIZE);

    struct rsa_key out;
    rsa_parse_priv_key(&out, arg->key, arg->key_len);
}
```

- 用户态利用kfuzztest-bridge 命令行工具触发内核态执行 test_rsa_parse_pub

```
kfuzztest-bridge "rsa_parse_pub_key_arg { ptr[key] len[key_len, u64] }; key { arr[u8, 512] };" test_rsa_parse_pub_key /dev/urandom
```

### 测试命令

```
# 测试缓冲区下溢
kfuzztest-bridge "some_buffer { ptr[buf] len[buf, u64] }; buf { arr[u8, 64] };" test_underflow_on_buffer /dev/urandom

# 测试嵌套缓冲区溢出
kfuzztest-bridge "nested_buffers { ptr[a] len[a, u64] ptr[b] len[b, u64] }; a { arr[u8, 32] }; b { arr[u8, 32] };" test_overflow_on_nested_buffer /dev/urandom

# 测试PKCS#7解析
kfuzztest-bridge "pkcs7_parse_message_arg { ptr[data] len[datalen, u64] }; data { arr[u8, 1024] };" test_pkcs7_parse_message /dev/urandom

# 测试RSA公钥解析
kfuzztest-bridge "rsa_parse_pub_key_arg { ptr[key] len[key_len, u64] }; key { arr[u8, 512] };" test_rsa_parse_pub_key /dev/urandom
```

## 缓冲区下溢测试输出

```
# kfuzztest-bridge "some_buffer { ptr[buf] len[buf, u64] }; buf { arr[u8, 64] };" test_underflow_on_buffer /dev/urandom

[ 8.918568] random: crng init done
[ 8.919036] buf = [ffff888104513550, ffff888104513590)
[ 8.919042] ==================================================================
[ 8.920199] BUG: KASAN: slab-out-of-bounds in kfuzztest_write_cb_test_underflow_on_buffer+0x1cf/0x220
[ 8.921026] Read of size 1 at addr ffff88810451354f by task kfuzztest-bridg/115
[ 8.921676]
[ 8.921829] CPU: 3 UID: 0 PID: 115 Comm: kfuzztest-bridg Tainted: G N 6.17.0-rc4-g1d203b2fed50-dirty #2 PREEMPT(voluntary)
[ 8.921834] Tainted: [N]=TEST
[ 8.921835] Hardware name: QEMU Standard PC (i440FX + PIIX, 1996), BIOS rel-1.15.0-0-g2dd4b9b3f840-prebuilt.qemu.org 04/01/2014
[ 8.921837] Call Trace:
[ 8.921838] <TASK>
[ 8.921839] dump_stack_lvl+0x55/0x70
[ 8.921845] print_report+0xcb/0x610
[ 8.921849] ? kfuzztest_write_cb_test_underflow_on_buffer+0x1cf/0x220
[ 8.921852] kasan_report+0xb8/0xf0
[ 8.921855] ? kfuzztest_write_cb_test_underflow_on_buffer+0x1cf/0x220
[ 8.921858] kfuzztest_write_cb_test_underflow_on_buffer+0x1cf/0x220
[ 8.921861] ? __pfx_kfuzztest_write_cb_test_underflow_on_buffer+0x10/0x10
[ 8.921864] ? _raw_spin_lock+0x7f/0xd0
[ 8.921869] full_proxy_write+0xf9/0x180
[ 8.921874] vfs_write+0x21e/0xc90
[ 8.921878] ? kmem_cache_free+0x133/0x380
[ 8.921884] ? __pfx_vfs_write+0x10/0x10
[ 8.921887] ? do_sys_openat2+0xea/0x160
[ 8.921890] ? __pfx_do_sys_openat2+0x10/0x10
[ 8.921894] ? fdget_pos+0x1c8/0x4c0
[ 8.921899] ksys_write+0xee/0x1c0
[ 8.921901] ? __pfx_ksys_write+0x10/0x10
[ 8.921903] ? do_user_addr_fault+0x480/0x9c0
[ 8.921908] do_syscall_64+0xa8/0x270
[ 8.921911] entry_SYSCALL_64_after_hwframe+0x77/0x7f
[ 8.921914] RIP: 0033:0x7f11bc1b6727
[ 8.921917] Code: 48 89 fa 4c 89 df e8 28 ad 00 00 8b 93 08 03 00 00 59 5e 48 83 f8 fc 74 1a 5b c3 0f 1f 84 00 00 00 00 00 48 8b 44 24 10 0f 05 <5b> c3 0f 1f 80 00 00 00 00 83 e2 39 83f
[ 8.921920] RSP: 002b:00007ffc0e8ceb70 EFLAGS: 00000202 ORIG_RAX: 0000000000000001
[ 8.921924] RAX: ffffffffffffffda RBX: 00007f11bc126740 RCX: 00007f11bc1b6727
[ 8.921926] RDX: 0000000000000098 RSI: 0000000022d50550 RDI: 0000000000000004
[ 8.921928] RBP: 0000000000000004 R08: 0000000000000000 R09: 0000000000000000
[ 8.921929] R10: 0000000000000000 R11: 0000000000000202 R12: 0000000000000000
[ 8.921931] R13: 00007ffc0e8d0f36 R14: 0000000022d50550 R15: 0000000000000098
[ 8.921934] </TASK>
[ 8.921934]
[ 8.938730] Allocated by task 115:
[ 8.939036] kasan_save_stack+0x24/0x50
[ 8.939380] kasan_save_track+0x14/0x30
[ 8.939726] __kasan_kmalloc+0x7f/0x90
[ 8.940064] __kmalloc_noprof+0x18a/0x430
[ 8.940425] kfuzztest_write_cb_test_underflow_on_buffer+0x76/0x220
[ 8.940976] full_proxy_write+0xf9/0x180
[ 8.941326] vfs_write+0x21e/0xc90
[ 8.941635] ksys_write+0xee/0x1c0
[ 8.941941] do_syscall_64+0xa8/0x270
[ 8.942270] entry_SYSCALL_64_after_hwframe+0x77/0x7f
[ 8.942717]
[ 8.942863] The buggy address belongs to the object at ffff888104513500
[ 8.942863] which belongs to the cache kmalloc-192 of size 192
[ 8.943944] The buggy address is located 31 bytes to the right of
[ 8.943944] allocated 48-byte region [ffff888104513500, ffff888104513530)
[ 8.945061]
[ 8.945203] The buggy address belongs to the physical page:
[ 8.945691] page: refcount:0 mapcount:0 mapping:0000000000000000 index:0x0 pfn:0x104513
[ 8.946389] flags: 0x200000000000000(node=0|zone=2)
[ 8.946823] page_type: f5(slab)
[ 8.947109] raw: 0200000000000000 ffff8881000423c0 dead000000000122 0000000000000000
[ 8.947783] raw: 0000000000000000 0000000080100010 00000000f5000000 0000000000000000
[ 8.948454] page dumped because: kasan: bad access detected
[ 8.948941]
[ 8.949091] Memory state around the buggy address:
[ 8.949519] ffff888104513400: fa fb fb fb fb fb fb fb fb fb fb fb fb fb fb fb
[ 8.950145] ffff888104513480: fb fb fb fb fb fb fb fb fc fc fc fc fc fc fc fc
[ 8.950773] >ffff888104513500: 00 00 00 00 00 00 fc 00 00 fc 00 00 00 00 00 00
[ 8.951403]                                                       ^
[ 8.951892] ffff888104513580: 00 00 fc fc fc fc fc fc fc fc fc fc fc fc fc fc
[ 8.952515] ffff888104513600: fc fc fc fc fc fc fc fc fc fc fc fc fc fc fc fc
[ 8.953141] ==================================================================
[ 8.953779] Disabling lock debugging due to kernel taint
#
#
```

## 参考
https://lwn.net/Articles/1038335/  
https://lwn.net/Articles/1038845/  
https://www.phoronix.com/news/Linux-KFuzz  
https://patchew.org/linux/20250919145750.3448393-1-ethan.w.s.graham@gmail.com/20250919145750.3448393-11-ethan.w.s.graham@gmail.com/
