---
layout:     post
title:      spinlock lockup suspected on CPU
subtitle:   一次喂cpld狗触发的死锁
date:       2024-02-29
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - lock
---

## 简介
产品反馈系统配置ptp时打印死锁异常，并且每次锁的持有者都不相同。其中一次异常栈如下  
这里的锁是cpu 0 的 `rq->lock` 队列锁。
```
[ 2269.552599] BUG: spinlock lockup suspected on CPU#1, swapper/1/0
[ 2269.624511]  lock: 0xffffffe0fff28500, .magic: dead4ead, .owner: bRX1/789, .owner_cpu: 0
[ 2269.721407]
#owner's Call trace:
[ 2269.762067] [<ffffff804008598c>] __switch_to+0x94/0xa0
[ 2269.823550] [<ffffff8040381318>] touch_nmi_watchdog_simple+0x18/0x28
[ 2269.899617] [<ffffff8040588d3c>] __schedule+0x194/0x798
[ 2269.962140] [<ffffff8040589388>] schedule+0x48/0xb0
[ 2269.993052] BUG: spinlock lockup suspected on CPU#3, kdrvfwdd3/857
[ 2269.993067]  lock: 0xffffffe0fff28500, .magic: dead4ead, .owner: bRX1/789, .owner_cpu: 0
[ 2269.993081]
[ 2269.993081] #owner's Call trace:
[ 2269.993093] [<ffffff804008598c>] __switch_to+0x94/0xa0
[ 2269.993105] [<ffffff8040381318>] touch_nmi_watchdog_simple+0x18/0x28
[ 2269.993118] [<ffffff8040588d3c>] __schedule+0x194/0x798
[ 2269.993128] [<ffffff8040589388>] schedule+0x48/0xb0
[ 2269.993138] [<ffffff804058d2e0>] schedule_timeout+0x118/0x230
[ 2270.017076] [<ffffff8006d351c0>] sal_sem_take+0x1a0/0x220 [system]
[ 2270.040699] [<ffffff8003ed0a94>] rx_chan_pkt_thread+0x6b4/0x9e0 [system]
[ 2270.064554] [<ffffff8006d33c04>] thread_boot+0x54/0x80 [system]
[ 2270.087871] [<ffffff80016efd48>] mdcThreadHook+0x220/0x298 [system]
[ 2270.087889] [<ffffff80400d421c>] kthread+0xfc/0x110
[ 2270.087900] [<ffffff8040082ac0>] ret_from_fork+0x10/0x50
[ 2270.087913] CPU: 3 PID: 857 Comm: kdrvfwdd3 Tainted: P S         O    4.4.65 #1
[ 2270.087927] Hardware name: E2000Q DEMO DDR4 (DT)
[ 2270.087937] Call trace:
[ 2270.087944] [<ffffff8040088a08>] dump_backtrace+0x0/0x1b0
[ 2270.087956] [<ffffff8040089030>] show_stack+0x20/0x28
[ 2270.087968] [<ffffff80403670cc>] dump_stack+0xb4/0xf0
[ 2270.087979] [<ffffff80400fcedc>] spin_dump+0x84/0x110
[ 2270.087989] [<ffffff80400fd13c>] do_raw_spin_lock+0x18c/0x1c0
[ 2270.088000] [<ffffff804058ddb8>] _raw_spin_lock+0x28/0x30
[ 2270.088012] [<ffffff80400df948>] try_to_wake_up+0x198/0x3b8   //
[ 2270.088023] [<ffffff80400dfc5c>] default_wake_function+0x1c/0x28
[ 2270.088037] [<ffffff804021d37c>] pollwake+0x6c/0x78
[ 2270.088047] [<ffffff80400f4c08>] __wake_up_common+0x68/0xa8
[ 2270.088058] [<ffffff80400f4c98>] __wake_up+0x50/0x70
......   // 后续业务栈省略掉了
```

`try_to_wake_up+0x198/0x3b8` 对应到`ttwu_queue`函数1094行代码   
显然是cpu 3 和 cpu 1 拿不到 cpu 0 的 `rq->lock` 队列锁，所以才打印了上面的死锁栈
```
1892 static void ttwu_queue(struct task_struct *p, int cpu)
1893 {
1894         struct rq *rq = cpu_rq(cpu);
1895
1896 #if defined(CONFIG_SMP)
1897         if (sched_feat(TTWU_QUEUE) && !cpus_share_cache(smp_processor_id(), cpu)) {
1898                 sched_clock_cpu(cpu); /* sync clocks x-cpu */
1899                 ttwu_queue_remote(p, cpu);
1900                 return;
1901         }
1902 #endif
1903
1904         raw_spin_lock(&rq->lock);    // 这里其它cpu拿不到cpu 0 的rq->lock
1905         lockdep_pin_lock(&rq->lock);
1906         ttwu_do_activate(rq, p, 0);
1907         lockdep_unpin_lock(&rq->lock);
1908         raw_spin_unlock(&rq->lock);
1909 }
```

## 分析
这里交代下背景，内核给所有产品开放了一个注册喂狗回调的接口，可以让各个产品注册自己的喂狗实现函数。    
以前的开发同事把这个喂狗接口放在`__schedule`里面。  

根据多次的异常就注意到一个现象，每次异常 cpu 0 上 `rq->lock` 持有者的栈都夹杂着一个喂狗函数  
`[ 2269.993105] [<ffffff8040381318>] touch_nmi_watchdog_simple+0x18/0x28`  
这个喂狗函数看着挺突兀，竟然保留在进程的内核栈上，  
喂狗操作只是写一下cpld某个寄存器，执行完应该从栈上退出才对，不应该留在栈上。

另外根据进程切换实现，prev 进程拿的`rq->lock`是由 next 进程负责释放的，  
并且处于关中断上下文，应该没有谁会打断这个过程。
```
__schedule
	raw_spin_lock_irq(&rq->lock);
	if (likely(prev != next)) {
	   touch_nmi_watchdog_simple();     // 这里调用驱动回调喂cpld狗
		 context_switch
            switch_to(prev, next, prev);  // prev进程从cpu上切出去，next进程从这里返回切回cpu
            barrier();
            finish_task_switch //  next进程继续执行，收尾工作
                finish_lock_switch
                    raw_spin_unlock_irq(&rq->lock); //释放prev进程拿着的rq lock
	} else {
        raw_spin_unlock_irq(&rq->lock);
    }
```

所以就怀疑喂狗有问题，把喂狗的函数直接注释掉之后，问题果然不再复现。  

然后加了些调试打印，在`spin_dump`里直接把`rq->lock`的数值打了出来，  
同时修改了喂狗函数，加了个`raw_spinlock_t *`指针参数，喂狗前后都加了`trace_printk`打印，也把锁数值打印出来  
```
[ 3754.415643] BUG: spinlock lockup suspected on CPU#3, kdrvfwdd3/864, lockcnt 0xa521a520
[ 3754.510456]  lock: 0xffffffe0fff28500, .magic: dead4ead, .owner: bRX1/799, .owner_cpu: 0
[ 3755.412762] CPU: 3 PID: 864 Comm: kdrvfwdd3 Tainted: P S         O    4.4.65 #1
[ 3755.500279] Hardware name: E2000Q DEMO DDR4 (DT)
[ 3755.555501] Call trace:
[ 3755.584683] [<ffffff8040088a08>] dump_backtrace+0x0/0x1b0
[ 3755.649286] [<ffffff8040089030>] show_stack+0x20/0x28
[ 3755.709724] [<ffffff80403671cc>] dump_stack+0xb4/0xf0
[ 3755.770159] [<ffffff80400fcf94>] spin_dump+0x94/0x100
[ 3755.830595] [<ffffff80400fd1f4>] do_raw_spin_lock+0x1ac/0x208
[ 3755.899367] [<ffffff804058dad0>] _raw_spin_lock+0x28/0x30
[ 3755.963969] [<ffffff80400df9f0>] try_to_wake_up+0x198/0x3b8
[ 3756.030655] [<ffffff80400dfd04>] default_wake_function+0x1c/0x28
[ 3756.102551] [<ffffff80400f4cb0>] __wake_up_common+0x68/0xa8
[ 3756.169237] [<ffffff80400f4d80>] __wake_up_locked+0x20/0x28
[ 3756.235925] [<ffffff8040577b40>] ep_poll_callback+0xb0/0x140
[ 3756.303652] [<ffffff80400f4cb0>] __wake_up_common+0x68/0xa8
[ 3756.370339] [<ffffff80400f4d40>] __wake_up+0x50/0x70
[ 3756.429727] [<ffffff8040579748>] kque_write+0x188/0x4a8
[ 3758.829816] KGDB: Timed out waiting for secondary CPUs.
Entering kdb (current=0xffffffdfbe6f3a00, pid 864) on processor 3 due to Keyboard Entry
[3]kdb>
[3]kdb>
[3]kdb>ftdump 72800 0  // 跳过前面的大量打印
.....
<idle>-0       0d..2 358527981us : __schedule: [2842] ocpu 0, prev swapper/0, next Drv_OHPktThread, lkcnt 0xa51fa51e
Drv_OHPk-1828    0d..2 358527982us : finish_task_switch: [2706] ocpu 0, prev swapper/0, curr Drv_OHPktThread, lkcnt 0xa51fa51e
Drv_OHPk-1828    0...1 358527983us : finish_task_switch: [2712] ocpu -1, prev swapper/0, curr Drv_OHPktThread, lkcnt 0xa51fa51f
Drv_OHPk-1828    0d..2 358527989us : touchdog2: [87] ocpu 0, dog lkcnt 0xa520a51f
Drv_OHPk-1828    0d..2 358527991us : touchdog2: [93] ocpu 0, dog lkcnt 0xa520a51f
Drv_OHPk-1828    0d..2 358527992us : __schedule: [2842] ocpu 0, prev Drv_OHPktThread, next bRX1, lkcnt 0xa520a51f
  bRX1-799     0d..2 358527993us : finish_task_switch: [2706] ocpu 0, prev Drv_OHPktThread, curr bRX1, lkcnt 0xa520a51f
  bRX1-799     0...1 358527994us+: finish_task_switch: [2712] ocpu -1, prev Drv_OHPktThread, curr bRX1, lkcnt 0xa520a520
  bRX1-799     0d..2 358528005us : touchdog2: [87] ocpu 0, dog lkcnt 0xa521a520                                                                                                                                             
[3]kdb>
[3]kdb> cpus
Currently on cpu  3
Available cpus: 0(D), 1(I), 2(D), 3   // cpu 0 和 cpu 2 都挂死了
[3]kdb>  
```

`lockcnt 0xa521a520` 就是序号锁的数值， `0xa520`表示0核确实没有释放队列锁  
另外缓冲区里的打印也截止到喂狗前的打印，喂狗后的调试信息没有打印出来  
显然cpu 0直接挂死在这个喂狗指令上了。  

咨询产品同事cpld的寄存器读写是否需要并发保护，回答是不加锁同样的SoC方案的其它设备均无问题。  
然后他们测试了加上自旋锁保护的情况，该死锁问题同样不再出现。  
也就是说cpld的并发读或者写导致cpu直接挂住了，最后证实2核读cpld和0核喂狗写cpld就会导致该问题。  

为什么cpld的并发读写会导致cpu挂住的问题咨询了fae，待反馈。

## 参考
[linux-4.4.65](https://elixir.bootlin.com/linux/v4.4.65/source)
