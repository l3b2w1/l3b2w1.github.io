---
layout:     post
title:      spinlock lockup caused by stack memory corruption
subtitle:   栈内存被写坏触发了系统死锁
date:       2024-08-23
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - lock
    - arm64
    - memory
---

## 死锁异常
产品反馈设备死锁，异常信息如下:  
```
[530.486893] BUG: spinlock lockup suspected on CPU#0, prd/22535
[530.557833] Unable to handle kernel paging request at virtual address d280003552829470
[530.652719] pgd = ffff80008bf8e000
[530.693341] [d280003552829470] *pgd=000000008f35c003, *pud=0000000000000000
[530.776671] Internal error: Oops: 96000004 [#1] SMP
[530.835103] Modules linked in: sys(PO) add(O)
[530.892394] CPU: 0 PID: 22535 Comm: prd Tainted: P S      W  O    4.4.65 #1
[530.976865] Hardware name: Model: Marvell CN9130 development board (CP NOR) setup(A) (DT)
[531.074879] task: ffff800050af8e80 ti: ffff80008aad0000 task.ti: ffff80008aad0000
[531.164569] PC is at spin_dump+0x68/0x1d0
[531.212586] LR is at spin_dump+0x58/0x1d0
[531.260604] pc : [<ffff0000800fd690>] lr : [<ffff0000800fd680>] pstate: 600001c5
[531.349243] sp : ffff80008aadfac0
[531.388823] x29: ffff80008aadfac0 x28: ffff000089001470
[531.452361] x27: ffff0000890014e0 x26: ffff80008aadfca0
[531.515899] x25: ffff0000032a8eb0 x24: ffff000000f00004
[531.579435] x23: 0000000000000000 x22: ffff000089001470
[531.642974] x21: ffff80008aad0000 x20: d280003552829180
[531.706511] x19: ffff000000f00004 x18: ffff000100cbd3bf
[531.770048] x17: ffff80008aadee9c x16: ffff00008011fdc0
[531.833586] x15: ffff000080cbd3cd x14: 0ffffffffffffffe
[531.897124] x13: 0000000000000020 x12: 0000000000000006
[531.960661] x11: 0000000000080000 x10: 0000000000076ded
[532.024199] x9 : ffff000080102518 x8 : 5043206e6f206465
[532.087737] x7 : 00000000000003ba x6 : 0002faf080000000
[532.151274] x5 : 0000000072a1e0c2 x4 : ffff000080db4000
[532.214812] x3 : 0000000000000000 x2 : 0000000052800063
[532.278350] x1 : 0000000000000033 x0 : ffff000080780000
[536.448499] Call trace:
[536.477666] [<ffff0000800fd690>] spin_dump+0x68/0x1d0
[536.538183] [<ffff0000800fd984>] do_raw_spin_lock+0x18c/0x1c0
[536.607035] [<ffff0000805daa1c>] _raw_spin_lock_irqsave+0x44/0x58
[536.680048] [<ffff0000800fb0a8>] up+0x20/0x78
[536.743370] [<ffff000000a3f2f8>] sem_up+0x18/0x20 [sys]
[536.820267] [<ffff0000010df6b0>] dev_handle_change+0x208/0x380 [sys]
...... // 省掉部分业务栈
[537.478718] [<ffff0000805c8a24>] sys_cioctl+0x24/0x38
[537.539234] [<ffff000080082e10>] el0_svc_naked+0x84/0xf4
```

## 定位过程
锁是个全局的二元信号量 struct semaphore。kdb里根据地址获取锁结构体字段如下   
各个字段都看着都挺正常，并且`00070007`表示锁其实是unlocked。  
锁unlock的情况下业务线程却拿不到，并触发死锁异常，这就不应该了。  
```
kdb> md4 glock
0xffff000004f00e10 00070007 dead4ead ffffffff 00000000   .....N.......... // owner:next ; magic dead4ead ; owner_cpu ffffffff没有cpu持锁。
0xffff000004f00e20 ffffffff ffffffff 00000000 00000000   ................	// owner   ;    count字段为0
0xffff000004f00e30 04f00e30 ffff0000 04f00e30 ffff0000   0.......0.......	// wait_list    prev和next都指向信号量自己。
```

分析驱动函数汇编，锁地址其实是x24寄存器赋值过来的。glock信号量合法地址是`0xffff000004f01410`   
但是异常寄存器现场显示 x24 的值为 `0xffff000000f00004`。**x24的值在函数入口已经保存到栈上了。所以大概率栈被写坏。**
```
0xffff0000010f8a8c dev_handle_change<+492>:   mov       x0, x24
0xffff0000010f8a90 dev_handle_change<+496>:   bl        0xffff0000010f87f0 sem_up
```

```
[0]kdb> id dev_handle_change
0xffff0000010f88a0 dev_handle_change:         mov       x9, x30                                                            
0xffff0000010f88a4 dev_handle_change<+4>:     nop                                                                          
0xffff0000010f88a8 dev_handle_change<+8>:     mov       x30, x9                                                            
0xffff0000010f88ac dev_handle_change<+12>:    stp       x29, x30, [sp, #-96]!                                              
0xffff0000010f88b0 dev_handle_change<+16>:    mov       x29, sp                                                            
0xffff0000010f88b4 dev_handle_change<+20>:    stp       x19, x20, [sp, #16]                                                
0xffff0000010f88b8 dev_handle_change<+24>:    stp       x21, x22, [sp, #32]                                                
0xffff0000010f88bc dev_handle_change<+28>:    stp       x23, x24, [sp, #48]  // 保存                                              
0xffff0000010f88c0 dev_handle_change<+32>:    stp       x25, x26, [sp, #64]
```

在该函数所有涉及到 x24 寄存器的汇编指令前后插入探测点，还好没几处。观察何时 x24 里的值从合法变为非法。  
```
echo 'p:x24a dev_handle_change+28 x24=%x24' >> kprobe_events
echo 'p:x24b dev_handle_change+164 x24=%x24' >> kprobe_events
echo 'p:x24c dev_handle_change+256 x24=%x24' >> kprobe_events
echo 'p:x29a dev_handle_change+32 x29=%x29' >> kprobe_events
echo 'p:x24d dev_handle_change+492 x24=%x24' >> kprobe_events
echo 'p:x24e dev_handle_change+524 x24=%x24' >> kprobe_events
echo 'p:x24f dev_handle_change+536 x24=%x24' >> kprobe_events
echo 'p:x24g dev_handle_change+564 x24=%x24' >> kprobe_events
echo 'p:x24h dev_handle_change+656 x24=%x24' >> kprobe_events
echo 'p:x24i dev_handle_change+740 x24=%x24' >> kprobe_events
echo 'p:x24j dev_handle_change+768 x24=%x24' >> kprobe_events
```

复现后设备异常进kdb，执行ftdump命令，x24寄存器数值变化过程如下  
`p:x24d`时信号量地址合法，而`p:x24e`时地址就变成了异常时的非法值。  
二者之间刚好调用到另外一个函数`dev_addif`。嫌疑犯就找到了。  
```
[0]kdb> ftdump
Dumping ftrace buffer:
---------------------------------
    pbrd-22538   0d... 1806268529us : x24a: (dev_handle_change+0x1c/0x3a8 [sys]) x24=0xffff000089001438
    pbrd-22538   0d... 1806268536us+: x29a: (dev_handle_change+0x20/0x3a8 [sys]) x29=0xffff8000894efbb0
    pbrd-22538   0d... 1806268630us : x24b: (dev_handle_change+0xa4/0x3a8 [sys]) x24=0xffff000004f01410
    pbrd-22538   0d... 1806268632us$: x24d: (dev_handle_change+0x1ec/0x3a8 [sys]) x24=0xffff000004f01410
    pbrd-22538   0dn.. 2027991968us@: x24e: (dev_handle_change+0x20c/0x3a8 [sys]) x24=0xffff000000f00004
    pbrd-22538   0dn.. 2028095249us : x24f: (dev_handle_change+0x218/0x3a8 [sys]) x24=0xffff000000f00004
---------------------------------
```

进一步确认，在该函数入口和出口直接kdb bp 加断点
```
[0]kdb> id dev_addif
0xffff000000957fd0 dev_addif:         mov  x9, x30
0xffff000000957fd4 dev_addif<+4>:     nop
0xffff000000957fd8 dev_addif<+8>:     mov  x30, x9
0xffff000000957fdc dev_addif<+12>:     sub sp, sp, #0x150
0xffff000000957fe0 dev_addif<+16>:    stp  x29, x30, [sp, #16]
0xffff000000957fe4 dev_addif<+20>:    add  x29, sp, #0x10
0xffff000000957fe8 dev_addif<+24>:    stp  x23, x24, [sp, #64]	// 保存父函数x24寄存器，断点加到这里
```
```
[0]kdb>
0xffff000000958150 dev_addif<+384>:   mov  sp, x29
0xffff000000958154 dev_addif<+388>:   mov  x0, x20
0xffff000000958158 dev_addif<+392>:   ldp  x19, x20, [sp, #16]
0xffff00000095815c dev_addif<+396>:   ldp  x21, x22, [sp, #32]
0xffff000000958160 dev_addif<+400>:   ldp  x23, x24, [sp, #48]	// 恢复父函数x24寄存器
0xffff000000958164 dev_addif<+404>:   ldp  x25, x26, [sp, #64]	// kdb 断点加到这里
0xffff000000958168 dev_addif<+408>:   ldp  x27, x28, [sp, #80]
0xffff00000095816c dev_addif<+412>:   ldp  x29, x30, [sp], #320
0xffff000000958170 dev_addif<+416>:   ret
0xffff000000958174 dev_addif<+420>:   nop
````

然后根据SP和偏移查看内存`0xffff80008c3ffaa8`存储的信号量地址，  
对比看到 `0xffff80008c3ffaa0`开始的16字节内容有修改。
```
[0]kdb> md 0xffff80008c3ffa60  // 函数入口断点进kdb                                                                                           
0xffff80008c3ffa60 ffff80008c3ffb70 ffffff80ffffffc8   p.?.............                                                             
0xffff80008c3ffa70 ffff80008c3ffbb0 ffff0000800abdd0   ..?.............                                                             
0xffff80008c3ffa80 0000000000000001 ffff000089001438   ........8.......                                                             
0xffff80008c3ffa90 00000000000005b1 ffff000089001470   ........p.......                                                             
0xffff80008c3ffaa0 ffff0000032a92a8 ffff000004f01410   ..*.............   // ffff000004f01410 合法地址                                                         
0xffff80008c3ffab0 ffff0000032a8c70 ffff80008c3ffca0   p.*.......?.....                                                             
0xffff80008c3ffac0 ffff0000890014e0 ffff000089001470   ........p.......                                                             
```

```
[2]kdb> md 0xffff80008c3ffa60  // 函数出口断点进kdb                                                                                                
0xffff80008c3ffa60 0001000000000000 ffffff80ffffffc8   ................                                                             
0xffff80008c3ffa70 ffff80008c3ffbb0 ffff0000800abdd0   ..?.............                                                             
0xffff80008c3ffa80 0000000000000001 ffff000089001438   ........8.......                                                             
0xffff80008c3ffa90 00000000000005b1 ffff000089001470   ........p.......                                                             
0xffff80008c3ffaa0 ff000004032a92a8 ffff000000f00004   ..*.............  // ffff000000f00004 非法地址                                                          
0xffff80008c3ffab0 ffff0000032a8c70 ffff80008c3ffca0   p.*.......?.....                                                             
0xffff80008c3ffac0 ffff0000890014e0 ffff000089001470   ........p.......                                                             
```

剩下的工作就交给产品驱动了，不再参与。  

## 参考
[linux-4.4.65](https://elixir.bootlin.com/linux/v4.4.65/source)
