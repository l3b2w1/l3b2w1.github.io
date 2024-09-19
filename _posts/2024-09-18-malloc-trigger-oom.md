---
layout:     post
title:      malloc trigger oom
subtitle:   malloc分配大块内存触发oom
date:       2024-09-18
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    -memory
---
## 问题描述
一般遇到的OOM，那就是OOM，确实可用内存剩余很少，申请不到触发的。  
这次遇到的OOM，从应用角度看明明还有好几百M，但就是分配失败了触发系统OOM异常。

```
root:/$ free -m
                    total       used       free     shared    buffers     cached
Mem:          1949        126       1823         70          0         70          // 刚启动时空闲内存1823M
-/+ buffers/cache:         56       1893
Swap:            0          0          0
root:/$
root:/$  oncealloc2 &    // 每次执行用户态程序 malloc分配128M，然后memset清零。
root:/$
root:/$ free -m   //  最后一次成功申请到128M，剩余空闲664M
             total       used       free     shared    buffers     cached
Mem:          1949       1285        664         70          0         70
-/+ buffers/cache:       1215        734
Swap:            0          0          0
```

再一次申请128M时，触发OOM，其中内存统计信息如下
```
[   89.906443] Node 0 DMA32 free:613120kB min:91584kB low:114432kB high:137280kB active_anon:1315328kB
inactive_anon:6208kB active_file:0kB inactive_file:0kB unevictable:0kB writepending:0kB present:2031616kB
managed:1996672kB mlocked:0kB kernel_stack:5760kB pagetables:2624kB bounce:0kB free_pcp:2496kB local_pcp:1088kB free_cma:523776kB
```
可以看到: **free:613120kB**，系统剩余可用内存600M；  **free_cma:523776kB**，cma区域预留了512M  
613120 -  523776 = 89344 / 1024 = 87.25M < 128M

dmesg里也有明确打印
```
[    0.000000] cma: Reserved 512 MiB at 0x00000000c0000000
```

CMA区域预留内存是给驱动通过DMA方式申请大块连续内存时用的，必须通过`dma_alloc_xxx`这样固定的接口。  
别说用户态进程 `malloc`了，就是内核态`kmalloc`都不能从这里分配。  

## 预留方式
1) arm架构dts文件中指定
```
linux,cma {
        compatible = "shared-dma-pool";
        inactive;
        reusable;
        reg = <0x00 0x10000000 0x04 0x000000>;
        linux,cma-default;
};
```

2) 内核传递参数指定  
`cma=nn[MG]@[start[MG][-end[MG]]]`

比如`cma=128M@1G`，从1G物理地址开始处预留128M。如果传递`cmd=0`，表示禁止系统预留CMA内存。

**一般不建议自己指定cma范围，留给系统启动阶段自行选择**  
因为一旦cma区域和其它专用区域重叠，很容易出现奇怪的问题。

## 完整打印
```
root:/$
[   89.758736] oncealloc2 invoked oom-killer: gfp_mask=0x100cca(GFP_HIGHUSER_MOVABLE), order=0, oom_score_adj=0
[   89.768559] CPU: 2 PID: 1440 Comm: oncealloc2 Tainted: G S                5.4.74 #14
[   89.776288] Hardware name: E2000Q DEMO DDR4 (DT)
[   89.780892] Call trace:
[   89.783414]  dump_backtrace+0x0/0x170
[   89.787064]  show_stack+0x24/0x30
[   89.790367]  dump_stack+0xe8/0x168
[   89.793756]  dump_header+0x48/0x200
[   89.797232]  out_of_memory+0x3d8/0x510
[   89.800968]  __alloc_pages_slowpath+0xb9c/0xe60
[   89.805486]  __alloc_pages_nodemask+0x2cc/0x360
[   89.810004]  alloc_pages_vma+0x90/0x228
[   89.813827]  __handle_mm_fault+0x558/0xeb0
[   89.817911]  handle_mm_fault+0xe8/0x1a8
[   89.821734]  do_page_fault+0x1c0/0x480
[   89.825471]  do_translation_fault+0x9c/0xb0
[   89.829641]  do_mem_abort+0x50/0xb0
[   89.833117]  el0_da+0x20/0x24
[   89.836071] User Call trace:
[   89.838939] ===> 0xffffa533f9bc
[   89.842154] ===> 0xaaaac8c20774
[   89.845378] Mem-Info:
[   89.847650] active_anon:20533 inactive_anon:97 isolated_anon:0
[   89.847650]  active_file:0 inactive_file:0 isolated_file:0
[   89.847650]  unevictable:0 dirty:0 writeback:0 unstable:0
[   89.847650]  slab_reclaimable:113 slab_unreclaimable:386
[   89.847650]  mapped:30 shmem:1121 pagetables:41 bounce:0
[   89.847650]  free:9580 free_pcp:39 free_cma:8184
[   89.879522] Node 0 active_anon:1314112kB inactive_anon:6208kB active_file:0kB inactive_file:0kB unevictable:0kB
 isolated(anon):0kB isolated(file):0kB mapped:1920kB dirty:0kB writeback:0kB shmem:71744kB shmem_thp: 0kB
 shmem_pmdmapped: 0kB anon_thp: 0kB writeback_tmp:0kB unstable:0kB all_unreclaimable? yes
[   89.906443] Node 0 DMA32 free:613120kB min:91584kB low:114432kB high:137280kB active_anon:1315328kB
inactive_anon:6208kB active_file:0kB inactive_file:0kB unevictable:0kB writepending:0kB present:2031616kB
managed:1996672kB mlocked:0kB kernel_stack:5760kB pagetables:2624kB bounce:0kB free_pcp:2496kB
local_pcp:1088kB free_cma:523776kB
[   89.935971] lowmem_reserve[]: 0 0 0
[   89.939459] Node 0 DMA32: 12*64kB (UM) 10*128kB (UM) 5*256kB (UM) 5*512kB (MC) 5*1024kB (UMC) 4*2048kB (MC) 3*4096kB (UMC)
 1*8192kB (C) 3*16384kB (UMC) 2*32768kB (MC) 1*65536kB (C) 1*131072kB (C) 1*262144kB (C) 0*524288kB = 613120kB
[   89.960072] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=16777216kB
[   89.968852] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=524288kB
[   89.977458] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=2048kB
[   89.985890] 1121 total pagecache pages
[   89.989634] 0 pages in swap cache
[   89.992946] Swap cache stats: add 0, delete 0, find 0/0
[   89.998168] Free swap  = 0kB
[   90.001044] Total swap = 0kB
[   90.003923] 31744 pages RAM
[   90.006713] 0 pages HighMem/MovableOnly
[   90.010544] 546 pages reserved
[   90.013594] 8192 pages cma reserved
[   90.017078] 0 pages hwpoisoned
[   90.020127] Tasks state (memory values in pages):
[   90.024827] [  pid  ]   uid  tgid total_vm      rss pgtables_bytes swapents oom_score_adj name
[   90.033440] [   1415]     0  1415       60       36   393216        0             0 ash
[   90.041439] [   1428]     0  1428     2082     2053   327680        0             0 oncealloc2
[   90.050046] [   1429]     0  1429     2082     2053   327680        0             0 oncealloc2
[   90.058655] [   1430]     0  1430     2082     2053   327680        0             0 oncealloc2
[   90.067263] [   1431]     0  1431     2082     2053   327680        0             0 oncealloc2
[   90.075869] [   1432]     0  1432     2082     2053   393216        0             0 oncealloc2
[   90.084479] [   1433]     0  1433     2082     2053   327680        0             0 oncealloc2
[   90.093086] [   1434]     0  1434     2082     2053   393216        0             0 oncealloc2
[   90.101694] [   1435]     0  1435     2082     2053   327680        0             0 oncealloc2
[   90.110301] [   1436]     0  1436     2082     2053   327680        0             0 oncealloc2
[   90.118908] [   1440]     0  1440     2081      998   393216        0             0 oncealloc2
[   90.127515] Kernel panic - not syncing: Out of memory: compulsory panic_on_oom is enabled
[   90.135678] Modules linked in:
[   90.138723] CPU: 2 PID: 1440 Comm: oncealloc2 Tainted: G S                5.4.74 #14
[   90.146451] Hardware name: E2000Q DEMO DDR4 (DT)
[   90.151057] pstate: 00000085 (nzcv daIf -PAN -UAO)
[   90.155836] pc : arch_get_regs+0x11c/0x140
[   90.159919] lr : arch_get_regs+0xb4/0x140
[   90.163915] sp : ffff80001736f6e0
[   90.167217] x29: ffff80001736f6e0 x28: 0000000000000000
[   90.172517] x27: 0000000000000000 x26: ffff80001736fc60
[   90.177816] x25: ffff800011b95700 x24: ffff00007bf73410
[   90.183115] x23: 0000000000000000 x22: ffff8000113d6460
[   90.188414] x21: ffff80001736f8c0 x20: ffff80001736f8e8
[   90.193713] x19: ffff800011b94000 x18: ffffffffffffffff
[   90.199013] x17: 6f5f6e6f5f63696e x16: 61702079726f736c
[   90.204312] x15: ffff800011b94d08 x14: 0000000000000000
[   90.209611] x13: 3a6e692064656b6e x12: 696c2073656c7564
[   90.214910] x11: 0000000005f5e0ff x10: ffff800011b95558
[   90.220209] x9 : 0000000000000000 x8 : ffff80001736f858
[   90.225508] x7 : 0000000000000000 x6 : 000000000000003f
[   90.230807] x5 : 0000000000000040 x4 : ffffffffffffffe0
[   90.236106] x3 : ffff80001736f718 x2 : 0000000000000008
[   90.241405] x1 : 0000000000000000 x0 : ffff80001736f718
[   90.246704] Call trace:
[   90.249225] User Call trace:
[   90.252093] ===> 0xffffa533f9bc
[   90.255308] ===> 0xaaaac8c20774
[   90.258524] monitor note oops info
[   90.262035] Monitor save item info
[   90.265424] Monitor notify normal exception cpu=2
[   90.270116] CPU: 2 PID: 1440 Comm: oncealloc2 Tainted: G S                5.4.74 #14
[   90.277845] Hardware name: E2000Q DEMO DDR4 (DT)
[   90.282449] Call trace:
[   90.284970]  dump_backtrace+0x0/0x170
[   90.288620]  show_stack+0x24/0x30
[   90.291923]  dump_stack+0xe8/0x168
[   90.295313]  panic+0x1cc/0x36c
[   90.298356]  out_of_memory+0x400/0x510
[   90.302092]  __alloc_pages_slowpath+0xb9c/0xe60
[   90.306610]  __alloc_pages_nodemask+0x2cc/0x360
[   90.311128]  alloc_pages_vma+0x90/0x228
[   90.314951]  __handle_mm_fault+0x558/0xeb0
[   90.319035]  handle_mm_fault+0xe8/0x1a8
[   90.322858]  do_page_fault+0x1c0/0x480
[   90.326595]  do_translation_fault+0x9c/0xb0
[   90.330765]  do_mem_abort+0x50/0xb0
[   90.334241]  el0_da+0x20/0x24
[   90.337195] User Call trace:
[   90.340063] ===> 0xffffa533f9bc
[   90.343278] ===> 0xaaaac8c20774
PANIC: Out of memory: compulsory panic_on_oom is enabled

Entering kdb (current=0xffff000020e12b80, pid 1440) on processor 2 due to Keyboard Entry

[2]kdb>
```

### 参考
[linux-5.4.74](https://elixir.bootlin.com/linux/v5.4.74/source)  
