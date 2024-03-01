---
layout:     post
title:      malloc trigger oom
subtitle:   记录一次malloc触发的oom异常
date:       2024-02-24
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - memory
---
## 简介
有一次据产品反馈，当时他在用户态malloc(128m)时，系统剩余内存还有六佰多兆就触发了系统oom。   
根据oom打印的内存使用情况记录，发现空闲剩余内存613120kB，cma空闲内存523776kB  
这应该不是巧合  
`free:613120kB`  
`free_cma:523776kB`  
`613120 -  523776 = 89344 / 1024 = 87.25M`  刚好小于128M  

查看dmesg信息，cma区域预留了512m
```
estuary:/$ dmesg |grep -i cma
[    0.000000] cma: cma_declare_contiguous(size 0x0000000004000000, base 0x0000000000000000, limit 0x00000000fc000000 alignment 0x0000000000000000)
[    0.000000] cma: Reserved 512 MiB at 0x00000000c0000000
[    0.000000] Memory: 1316544K/2031616K available (16316K kernel code, 1942K rwdata, 5504K rodata, 5312K init, 2160K bss, 190784K reserved, 524288K cma-reserved)
```

cma区域的内存通常用于分配给设备进行DMA操作的缓冲区。  
这对于需要物理上连续的内存的硬件是非常重要的，如一些网络设备和图形卡。  

内核态驱动代码可以使用dma api（比如dma_alloc_contiguous)从cma区域申请(cma_alloc)内存  
cma预留的这块内存占据了512M，不能用于用户态malloc内存分配
```
__alloc_pages_slowpath
	should_reclaim_retry
		for_each_zone_zonelist_nodemask
			min_wmark_pages
```

malloc陷入内核之后申请内存的标记位 `0x50cc0(GFP_KERNEL|__GFP_NORETRY|__GFP_COMP)`      
不能从cma区域分配，剩余的又不够，所以触发了OOM
```
__alloc_pages_nodemask
    prepare_alloc_pages
        ac->migratetype = gfpflags_to_migratetype(gfp_mask);
            if (IS_ENABLED(CONFIG_CMA) && ac->migratetype == MIGRATE_MOVABLE)
                  *alloc_flags |= ALLOC_CMA;
    __alloc_pages_slowpath
        gfp_to_alloc_flags(gfp_mask);
            if (gfpflags_to_migratetype(gfp_mask) == MIGRATE_MOVABLE)
                  alloc_flags |= ALLOC_CMA;
```
详细打印如下
```
estuary:/$  oncealloc2 134217728 &
[   88.955839] oncealloc2 invoked oom-killer: gfp_mask=0x100cca(GFP_HIGHUSER_MOVABLE), order=0, oom_score_adj=0
[   88.965666] CPU: 2 PID: 1440 Comm: oncealloc2 Tainted: G S                5.4.74 #14
[   88.973396] Hardware name: E2000Q DEMO DDR4 (DT)
[   88.978001] Call trace:
[   88.980526]  dump_backtrace+0x0/0x170
[   88.984177]  show_stack+0x24/0x30
[   88.987483]  dump_stack+0xe8/0x168
[   88.990873]  dump_header+0x48/0x200
[   88.994350]  out_of_memory_reboot+0x64/0x90
[   88.998520]  out_of_memory+0x80/0x510
[   89.002171]  __alloc_pages_slowpath+0xb9c/0xe60
[   89.006688]  __alloc_pages_nodemask+0x2cc/0x360
[   89.011208]  alloc_pages_vma+0x90/0x228
[   89.015032]  __handle_mm_fault+0x558/0xeb0
[   89.019116]  handle_mm_fault+0xe8/0x1a8
[   89.022940]  do_page_fault+0x1c0/0x480
[   89.026676]  do_translation_fault+0x9c/0xb0
[   89.030847]  do_mem_abort+0x50/0xb0
[   89.034323]  el0_da+0x20/0x24
[   89.046589] Mem-Info:
[   89.048862] active_anon:20533 inactive_anon:97 isolated_anon:0
[   89.048862]  active_file:0 inactive_file:0 isolated_file:0
[   89.048862]  unevictable:0 dirty:0 writeback:0 unstable:0
[   89.048862]  slab_reclaimable:113 slab_unreclaimable:386
[   89.048862]  mapped:30 shmem:1121 pagetables:41 bounce:0
[   89.048862]  free:9580 free_pcp:39 free_cma:8184
[   89.080735] Node 0 active_anon:1314112kB inactive_anon:6208kB active_file:0kB inactive_file:0kB unevictable:0kB isolated(anon):0kB isolated(file):0kB mapped:1920kB dirty:0kB writeback:0kB shmem:71744kB shmem_thp: 0kB shmem_pmdmapped: 0kB anon_thp: 0kB writeback_tmp:0kB unstable:0kB all_unreclaimable? yes
[   89.107655] Node 0 DMA32 free:613120kB min:91584kB low:114432kB high:137280kB active_anon:1315328kB inactive_anon:6208kB active_file:0kB inactive_file:0kB unevictable:0kB writepending:0kB present:2031616kB managed:1996672kB mlocked:0kB kernel_stack:5760kB pagetables:2624kB bounce:0kB free_pcp:2496kB local_pcp:1088kB free_cma:523776kB
[   89.137183] lowmem_reserve[]: 0 0 0
[   89.140672] Node 0 DMA32: 12*64kB (UM) 10*128kB (UM) 5*256kB (UM) 5*512kB (MC) 5*1024kB (UMC) 4*2048kB (MC) 3*4096kB (UMC) 1*8192kB (C) 3*16384kB (UMC) 2*32768kB (MC) 1*65536kB (C) 1*131072kB (C) 1*262144kB (C) 0*524288kB = 613120kB
[   89.161287] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=16777216kB
[   89.170067] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=524288kB
[   89.178673] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=2048kB
[   89.187105] 1121 total pagecache pages
[   89.190851] 0 pages in swap cache
[   89.194167] Swap cache stats: add 0, delete 0, find 0/0
[   89.199387] Free swap  = 0kB
[   89.202264] Total swap = 0kB
[   89.205142] 31744 pages RAM
[   89.207931] 0 pages HighMem/MovableOnly
[   89.211761] 546 pages reserved
[   89.214811] 8192 pages cma reserved
[   89.218295] 0 pages hwpoisoned
[   89.221346] Tasks state (memory values in pages):
[   89.226046] [  pid  ]   uid  tgid total_vm      rss pgtables_bytes swapents oom_score_adj name
[   89.234669] [   1415]     0  1415       60       36   393216        0             0 ash
[   89.242670] [   1428]     0  1428     2082     2053   327680        0             0 oncealloc2
[   89.251277] [   1429]     0  1429     2082     2053   327680        0             0 oncealloc2
[   89.259883] [   1430]     0  1430     2082     2053   327680        0             0 oncealloc2
[   89.268491] [   1431]     0  1431     2082     2053   327680        0             0 oncealloc2
[   89.277099] [   1432]     0  1432     2082     2053   393216        0             0 oncealloc2
[   89.285710] [   1433]     0  1433     2082     2053   327680        0             0 oncealloc2
[   89.294318] [   1434]     0  1434     2082     2053   393216        0             0 oncealloc2
[   89.302925] [   1435]     0  1435     2082     2053   327680        0             0 oncealloc2
[   89.311532] [   1436]     0  1436     2082     2053   327680        0             0 oncealloc2
[   89.320144] [   1440]     0  1440     2081      998   393216        0             0 oncealloc2
[   89.328750] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=/,mems_allowed=0,global_oom,task_memcg=/,task=oncealloc2,pid=1440,uid=0
[   89.341534] slab_printk_slabinfo is enable with CONFIG_SLUB and CONFIG_SLABINFO.Please check
[   89.350196] oncealloc2: page allocation failure: order:0, mode:0x50cc0(GFP_KERNEL|__GFP_NORETRY|__GFP_COMP), nodemask=(null),cpuset=/,mems_allowed=0
[   89.363497] oncealloc2: page allocation failure: mode:0x50cc0
[   89.369239] CPU: 2 PID: 1440 Comm: oncealloc2 Tainted: G S                5.4.74 #14
[   89.376969] Hardware name: E2000Q DEMO DDR4 (DT)
[   89.381572] Call trace:
[   89.384095]  dump_backtrace+0x0/0x170
[   89.387744]  show_stack+0x24/0x30
[   89.391048]  dump_stack+0xe8/0x168
[   89.394437]  warn_alloc+0x118/0x188
[   89.397913]  __alloc_pages_slowpath+0xe04/0xe60
[   89.402431]  __alloc_pages_nodemask+0x2cc/0x360
[   89.406950]  alloc_pages_current+0x88/0xe8
[   89.411034]  alloc_slab_page+0x174/0x460
[   89.414944]  new_slab+0x2bc/0x390
[   89.418247]  ___slab_alloc+0x418/0x5f0
[   89.421984]  __slab_alloc+0x68/0xc8
[   89.425460]  kmem_cache_alloc_trace+0x1fc/0x220
[   89.429979]  hardirqtrace_notify+0x2c/0x128
[   89.434150]  save_reboot_item_info+0x1d4/0x278
[   89.438581]  out_of_memory_reboot+0x74/0x90
[   89.442752]  out_of_memory+0x80/0x510
[   89.446401]  __alloc_pages_slowpath+0xb9c/0xe60
[   89.450919]  __alloc_pages_nodemask+0x2cc/0x360
[   89.455437]  alloc_pages_vma+0x90/0x228
[   89.459261]  __handle_mm_fault+0x558/0xeb0
[   89.463344]  handle_mm_fault+0xe8/0x1a8
[   89.467168]  do_page_fault+0x1c0/0x480
[   89.470905]  do_translation_fault+0x9c/0xb0
[   89.475075]  do_mem_abort+0x50/0xb0
[   89.478551]  el0_da+0x20/0x24
[   89.490816] Mem-Info:
[   89.493089] active_anon:20533 inactive_anon:97 isolated_anon:0
[   89.493089]  active_file:0 inactive_file:0 isolated_file:0
[   89.493089]  unevictable:0 dirty:0 writeback:0 unstable:0
[   89.493089]  slab_reclaimable:113 slab_unreclaimable:386
[   89.493089]  mapped:30 shmem:1121 pagetables:41 bounce:0
[   89.493089]  free:9580 free_pcp:39 free_cma:8184
[   89.524959] Node 0 active_anon:1314112kB inactive_anon:6208kB active_file:0kB inactive_file:0kB unevictable:0kB isolated(anon):0kB isolated(file):0kB mapped:1920kB dirty:0kB writeback:0kB shmem:71744kB shmem_thp: 0kB shmem_pmdmapped: 0kB anon_thp: 0kB writeback_tmp:0kB unstable:0kB all_unreclaimable? yes
[   89.551880] Node 0 DMA32 free:613120kB min:91584kB low:114432kB high:137280kB active_anon:1315328kB inactive_anon:6208kB active_file:0kB inactive_file:0kB unevictable:0kB writepending:0kB present:2031616kB managed:1996672kB mlocked:0kB kernel_stack:5760kB pagetables:2624kB bounce:0kB free_pcp:2496kB local_pcp:1088kB free_cma:523776kB
[   89.581407] lowmem_reserve[]: 0 0 0
[   89.584895] Node 0 DMA32: 12*64kB (UM) 10*128kB (UM) 5*256kB (UM) 5*512kB (MC) 5*1024kB (UMC) 4*2048kB (MC) 3*4096kB (UMC) 1*8192kB (C) 3*16384kB (UMC) 2*32768kB (MC) 1*65536kB (C) 1*131072kB (C) 1*262144kB (C) 0*524288kB = 613120kB
[   89.605508] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=16777216kB
[   89.614288] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=524288kB
[   89.622894] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=2048kB
[   89.631326] 1121 total pagecache pages
[   89.635071] 0 pages in swap cache
[   89.638382] Swap cache stats: add 0, delete 0, find 0/0
[   89.643601] Free swap  = 0kB
[   89.646477] Total swap = 0kB
[   89.649353] 31744 pages RAM
[   89.652143] 0 pages HighMem/MovableOnly
[   89.655973] 546 pages reserved
[   89.659023] 8192 pages cma reserved
[   89.662507] 0 pages hwpoisoned
[   89.665558] SLUB: Unable to allocate memory on node -1, gfp=0x10dc0(GFP_KERNEL|__GFP_NORETRY|__GFP_ZERO)
[   89.675024]   cache: kmalloc-16k, object size: 16384, buffer size: 16384, default order: 2, min order: 0
[   89.684490]   node 0: slabs: 2, objs: 32, free: 0
[   89.689188] no enough memory to save hardirqtrace hook info
[   89.694852] SLUB: Unable to allocate memory on node -1, gfp=0x10dc0(GFP_KERNEL|__GFP_NORETRY|__GFP_ZERO)
[   89.704318]   cache: kmalloc-128k, object size: 131072, buffer size: 131072, default order: 3, min order: 1
[   89.714044]   node 0: slabs: 2, objs: 8, free: 0
[   89.718657] no enough memory to save irqlocktrace hook info
[   89.724310] SLUB: Unable to allocate memory on node -1, gfp=0x10dc0(GFP_KERNEL|__GFP_NORETRY|__GFP_ZERO)
[   89.733775]   cache: kmalloc-128k, object size: 131072, buffer size: 131072, default order: 3, min order: 1
[   89.743501]   node 0: slabs: 2, objs: 8, free: 0
[   89.748116] no enough memory to save softlocktrace hook info
[   89.753771] OOM notifer drv save info and reboot end
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
[   89.845378] Mem-Info:
[   89.847650] active_anon:20533 inactive_anon:97 isolated_anon:0
[   89.847650]  active_file:0 inactive_file:0 isolated_file:0
[   89.847650]  unevictable:0 dirty:0 writeback:0 unstable:0
[   89.847650]  slab_reclaimable:113 slab_unreclaimable:386
[   89.847650]  mapped:30 shmem:1121 pagetables:41 bounce:0
[   89.847650]  free:9580 free_pcp:39 free_cma:8184
[   89.879522] Node 0 active_anon:1314112kB inactive_anon:6208kB active_file:0kB inactive_file:0kB unevictable:0kB isolated(anon):0kB isolated(file):0kB mapped:1920kB dirty:0kB writeback:0kB shmem:71744kB shmem_thp: 0kB shmem_pmdmapped: 0kB anon_thp: 0kB writeback_tmp:0kB unstable:0kB all_unreclaimable? yes
[   89.906443] Node 0 DMA32 free:613120kB min:91584kB low:114432kB high:137280kB active_anon:1315328kB inactive_anon:6208kB active_file:0kB inactive_file:0kB unevictable:0kB writepending:0kB present:2031616kB managed:1996672kB mlocked:0kB kernel_stack:5760kB pagetables:2624kB bounce:0kB free_pcp:2496kB local_pcp:1088kB free_cma:523776kB   //  613120 -  523776 = 89344 / 1024 = 87.25M < 128M
[   89.935971] lowmem_reserve[]: 0 0 0
[   89.939459] Node 0 DMA32: 12*64kB (UM) 10*128kB (UM) 5*256kB (UM) 5*512kB (MC) 5*1024kB (UMC) 4*2048kB (MC) 3*4096kB (UMC) 1*8192kB (C) 3*16384kB (UMC) 2*32768kB (MC) 1*65536kB (C) 1*131072kB (C) 1*262144kB (C) 0*524288kB = 613120kB
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
PANIC: Out of memory: compulsory panic_on_oom is enabled
Entering kdb (current=0xffff000020e12b80, pid 1440) on processor 2 due to Keyboard Entry
[2]kdb>
```
