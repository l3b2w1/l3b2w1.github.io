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
有一次据产品反馈，当时他在用户态malloc(128m)时，系统剩余内存还有五百多兆就触发了oom。   
根据oom打印的内存使用情况记录，发现空闲剩余内存529024kB，cma空闲内存524288K    
这应该不是巧合  
`DMA32 free:529024kB` - `free_cma:523848kB` = `5176k / 1024` = 5M < 128M

查看dmesg信息，cma区域预留了512m
```
estuary:/$ dmesg|grep cma -i
[    0.000000] Reserved memory: created CMA memory pool at 0x00000000d0000000, size 512 MiB
[    0.000000] OF: reserved mem: initialized node linux,cma, compatible id shared-dma-pool
[    0.000000] Memory: 1296092K/2031616K available (14780K kernel code, 2690K rwdata, 7160K rodata, 9152K init, 11868K bss, 211236K reserved, 524288K cma-reserved)
```

产品在dts文件里指定的
```
reserved-memory {
	#address-cells = <0x02>;
	#size-cells = <0x02>;
	ranges;
	phandle = <0x14e>;

	linux,cma {
		compatible = "shared-dma-pool";
		reusable;
		reg = <0x00 0xd0000000 0x00 0x20000000>;  // 512M
		linux,cma-default;
	};
};

```

cma区域的内存通常用于分配给设备进行DMA操作的缓冲区。  
这对于需要物理上连续的内存的硬件是非常重要的，如一些网络设备和图形卡。  

内核态驱动代码可以使用dma api（比如dma_alloc_coherent)从cma区域申请内存  
cma预留的这块内存占据了512M，不能用于用户态malloc内存分配

malloc陷入内核之后申请内存的标记位 `0x50cc0(GFP_KERNEL|__GFP_NORETRY|__GFP_COMP)`      
不能从cma区域分配，剩余的又不够，所以触发了OOM

根据实际情况预留即可，留多了浪费。  

## oom log
```
# free -m
             total       used       free     shared    buffers     cached
Mem:          1901        126       1775         87          0         87
-/+ buffers/cache:         38       1863
Swap:            0          0          0
#
# oom
[   23.403805] oom invoked oom-killer: gfp_mask=0x400dc0(GFP_KERNEL_ACCOUNT|__GFP_ZERO), order=0, oom_score_adj=0
[   23.413859] CPU: 2 PID: 147 Comm: oom Tainted: G S                5.4.74 #4
[   23.420815] Hardware name: E2000Q DEMO DDR4 (DT)
[   23.425425] Call trace:
[   23.427870]  dump_backtrace+0x0/0x150
[   23.431526]  show_stack+0x24/0x30
[   23.434838]  dump_stack+0xe8/0x168
[   23.438235]  dump_header+0x4c/0x3e0
[   23.441717]  out_of_memory+0x46c/0x598
[   23.445462]  __alloc_pages_slowpath+0xc28/0xfb8
[   23.449986]  __alloc_pages_nodemask+0x408/0x528
[   23.454511]  alloc_pages_current+0x88/0xf0
[   23.458603]  __pte_alloc+0x34/0x180
[   23.462085]  __handle_mm_fault+0xe50/0xec0
[   23.466175]  handle_mm_fault+0x18c/0x330
[   23.470092]  do_page_fault+0x208/0x428
[   23.473835]  do_translation_fault+0xa0/0xbc
[   23.478012]  do_mem_abort+0x54/0xb0
[   23.481494]  el0_da+0x1c/0x20
[   23.484478] Mem-Info:
[   23.486769] active_anon:325300 inactive_anon:19129 isolated_anon:0
[   23.486769]  active_file:0 inactive_file:0 isolated_file:0
[   23.486769]  unevictable:0 dirty:0 writeback:0 unstable:0
[   23.486769]  slab_reclaimable:2691 slab_unreclaimable:2768
[   23.486769]  mapped:424 shmem:22447 pagetables:636 bounce:0
[   23.486769]  free:132256 free_pcp:650 free_cma:130962
[   23.519883] Node 0 active_anon:1301200kB inactive_anon:76516kB active_file:0kB inactive_file:0kB unevictable:0kB isolated(anon):0kB isolated(file):0kB mapped:1696kB dirty:0kB writeback:0kB shmem:89788kB writeback_tmp:0kB unstable:0kB all_unreclaimable? yes
[   23.542584] Node 0 DMA32 free:529024kB min:5396kB low:7216kB high:9036kB active_anon:1301284kB inactive_anon:76516kB active_file:0kB inactive_file:0kB unevictable:0kB writepending:0kB present:2031616kB managed:1947352kB mlocked:0kB kernel_stack:1136kB pagetables:2544kB bounce:0kB free_pcp:2600kB local_pcp:496kB free_cma:523848kB
[   23.571705] lowmem_reserve[]: 0 0 0
[   23.575212] Node 0 DMA32: 4*4kB (UEC) 0*8kB 1*16kB (E) 5*32kB (UMEC) 1*64kB (E) 1*128kB (E) 3*256kB (UME) 1*512kB (C) 3*1024kB (UEC) 2*2048kB (MC) 127*4096kB (C) = 529024kB
[   23.590646] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=1048576kB
[   23.599356] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=32768kB
[   23.607890] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=2048kB
[   23.616339] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=64kB
[   23.624613] 22447 total pagecache pages
[   23.628464] 0 pages in swap cache
[   23.631791] Swap cache stats: add 0, delete 0, find 0/0
[   23.637029] Free swap  = 0kB
[   23.639921] Total swap = 0kB
[   23.642816] 507904 pages RAM
[   23.645691] 0 pages HighMem/MovableOnly
[   23.649541] 21066 pages reserved
[   23.652790] 131072 pages cma reserved
[   23.656469] 0 pages hwpoisoned
[   23.659537] Tasks state (memory values in pages):
[   23.664254] [  pid  ]   uid  tgid total_vm      rss pgtables_bytes swapents oom_score_adj name
[   23.672915] [    138]     0   138      836      435    45056        0             0 ash
[   23.680959] [    147]     0   147   328109   322172  2613248        0             0 oom
[   23.688979] Kernel panic - not syncing: Out of memory: system-wide panic_on_oom is enabled
[   23.697236] CPU: 2 PID: 147 Comm: oom Tainted: G S                5.4.74 #4
[   23.704190] Hardware name: E2000Q DEMO DDR4 (DT)
[   23.708800] Call trace:
[   23.711242]  dump_backtrace+0x0/0x150
[   23.714897]  show_stack+0x24/0x30
[   23.718207]  dump_stack+0xe8/0x168
[   23.721604]  panic+0x180/0x3d4
[   23.724652]  out_of_memory+0x48c/0x598
[   23.728395]  __alloc_pages_slowpath+0xc28/0xfb8
[   23.732919]  __alloc_pages_nodemask+0x408/0x528
[   23.737442]  alloc_pages_current+0x88/0xf0
[   23.741533]  __pte_alloc+0x34/0x180
[   23.745015]  __handle_mm_fault+0xe50/0xec0
[   23.749104]  handle_mm_fault+0x18c/0x330
[   23.753020]  do_page_fault+0x208/0x428
[   23.756763]  do_translation_fault+0xa0/0xbc
[   23.760939]  do_mem_abort+0x54/0xb0
[   23.764421]  el0_da+0x1c/0x20
PANIC: Out of memory: system-wide panic_on_oom is enabled

Entering kdb (current=0xffff000076e83600, pid 147) on processor 2 due to Keyboard Entry
[2]kdb>
```
