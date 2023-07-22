---
layout:     post
title:      拷贝大文件时系统异常
subtitle:   dts cma配置不当引起的panic
date:       2023-07-22
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - arm64
    - memory
    - panic
    - dts
---
### 问题背景信息
内核版本号5.4.74  

设备2G内存，使能CONFIG_TMPFS和CONFIG_SHMEM，使用内存文件系统

系统起来之后bash下执行`cp file1 file2`拷贝命令时panic，文件大小200M左右

问题基本必现，每次异常地址都是`0xffff000010080000`

**无论何种场合，执行用户态命令都不应该导致系统panic，除非内核或者驱动本身有问题。**

### panic 现场
`Unable to handle kernel write to read-only memory at virtual address ffff000010080000`  
信息显示访问了只读内存，内核不允许只读内存写入数据，所以触发panic
```
[root@ flash:]# free -h
            total        used        free         shared    buff/cache   available
Mem:          1.9Gi       753Mi       166Mi       537Mi       1.0Gi       646Mi
Swap:           0B          0B          0B
[root@ flash:]# cp ck1 ck2
[ 1166.931586] Unable to handle kernel write to read-only memory at virtual address ffff000010080000
[ 1166.940567] Mem abort info:
[ 1166.943377]   ESR = 0x9600004f
[ 1166.946444]   EC = 0x25: DABT (current EL), IL = 32 bits
[ 1166.951779]   SET = 0, FnV = 0
[ 1166.954846]   EA = 0, S1PTW = 0
[ 1166.958015] Data abort info:
[ 1166.960914]   ISV = 0, ISS = 0x0000004f
[ 1166.964775]   CM = 0, WnR = 1
[ 1166.967757] swapper pgtable: 4k pages, 48-bit VAs, pgdp=00000000112a0000
[ 1166.974495] [ffff000010080000] pgd=000000007eff8003, pud=000000007eff7003, pmd=000000007ef7f003, pte=0060000010080793
[ 1166.985153] Internal error: Oops: 9600004f [#1] SMP

Entering kdb (current=0xffff00002d5ba940, pid 16929) on processor 0 Oops: (null)
due to oops @ 0xffff800010dbcd30
CPU: 0 PID: 16929 Comm: cp Tainted: G           O      5.4.74 #1
Hardware name: Rockchip RK3566 EVB2 LP4X V10 Board (DT)
pstate: 20400009 (nzCv daif +PAN -UAO)
pc : __arch_copy_from_user+0x1b0/0xac0
lr : copyin+0x94/0xa8
sp : ffff800018e67b90
x29: ffff800018e67b90 x28: 0000000000000000
x27: 0000000000001000 x26: ffff800010e4d5d8
x25: 000000000001d000 x24: ffff00002f37ab00
x23: ffff800018e67d70 x22: ffff000010081000
x21: ffff800018e67d60 x20: 0000000000001000
x19: 0000000000000000 x18: 0000000000000000
x17: 0000000000000000 x16: 0000000000000000
x15: 0000000000000000 x14: 8f20dac0ef06f578
x13: b1cf6dfaf772e502 x12: cda2c606ffe3d16c
x11: c7a03f22f1088c31 x10: e79eab9579170b18
x9 : a0f007787ef15132 x8 : 7942e9e70a775f54
x7 : dda0afce8569c76b x6 : ffff000010080000
x5 : ffff000010081000 x4 : 0000000000000000
x3 : 0000ffffac3bd000 x2 : 0000000000000f80
x1 : 0000ffffac3bd040 x0 : ffff000010080000
Call trace:
 __arch_copy_from_user+0x1b0/0xac0
 iov_iter_copy_from_user_atomic+0xe8/0x388
 generic_perform_write+0x124/0x1a8
 __generic_file_write_iter+0x134/0x1b8
 generic_file_write_iter+0x110/0x188
 new_sync_write+0x108/0x188
 __vfs_write+0x34/0x48
 vfs_write+0xb8/0x1d8
 ksys_write+0x6c/0xf0
 __arm64_sys_write+0x20/0x28
 el0_svc_common.constprop.3+0x98/0x188
 el0_svc_handler+0x74/0x90
 el0_svc+0x8/0x640
User Call trace:

```

------------------------------------------

### 日志分析  
添加内核传参`memblock=debug`，部分启动log如下

由`PAGE_OFFSET is 0xffff000000000000`可知，`0xffff000010080000`虚拟地址是线性映射地址，对应物理内存地址`0x10080000`   
```
[    0.000000] arm64_memblock_init: physvirt_offset is 0x1000000000000, PHYS_OFFSET is 0x0, PAGE_OFFSET is 0xffff000000000000
[    0.000000] memblock_remove: [0x0000800000000000-0x00007ffffffffffe] arm64_memblock_init+0xfc/0x44c
[    0.000000] memblock_add: [0x0000000010080000-0x00000000119c0fff] arm64_memblock_init+0x164/0x44c
[    0.000000] memblock_remove: [0x0000000012200000-0x00000000176effff] arm64_memblock_init+0x1b8/0x44c
[    0.000000] memblock_add: [0x0000000012200000-0x00000000176effff] arm64_memblock_init+0x1c4/0x44c
[    0.000000] memblock_reserve: [0x0000000012200000-0x00000000176effff] arm64_memblock_init+0x1d0/0x44c
[    0.000000] memblock_reserve: [0x0000000010080000-0x00000000119c0fff] arm64_memblock_init+0x240/0x44c
[    0.000000] OF: fdt: Reserved memory: failed to reserve memory for node 'drm-logo@00000000': base 0x0000000000000000, size 0 MiB
[    0.000000] OF: fdt: Reserved memory: failed to reserve memory for node 'drm-cubic-lut@00000000': base 0x0000000000000000, size 0 MiB
[    0.000000] memblock_reserve: [0x0000000010000000-0x00000000107fffff] early_init_dt_reserve_memory_arch+0x24/0x2c
[    0.000000] memblock_reserve: [0x0000000000110000-0x00000000001fffff] early_init_dt_reserve_memory_arch+0x24/0x2c
[    0.000000] memblock_remove: [0x0000000000000000-0x00000000001fffff] early_init_dt_reserve_memory_arch+0x1c/0x2c
[    0.000000] memblock_remove: [0x0000000008400000-0x00000000093fffff] early_init_dt_reserve_memory_arch+0x1c/0x2c
[    0.000000] Reserved memory: created CMA memory pool at 0x0000000010000000, size 8 MiB
[    0.000000] OF: reserved mem: initialized node linux,cma, compatible id shared-dma-pool
```

1. `0x10080000` 是内核镜像kernel code 占据的内存起始物理地址，属于是可执行文本段，所以不允许写入。  
```
[root@ flash:]# cat /proc/iomem
00200000-083fffff : System RAM
09400000-7effffff : System RAM
10000000-1007ffff : reserved    
10080000-112affff : Kernel code   // 可执行文本段
112b0000-1171ffff : reserved
11720000-119bdfff : Kernel data
1216e000-1218efff : reserved
  ......
```

2. `memblock_reserve: [0x0000000010080000-0x00000000119c0fff] arm64_memblock_init+0x240/0x44c`  
从memblock debug日志可以看出来，Kernel code内存区域在memblock运行阶段已经做过保留，所以不会、也不应该提交给buddy system纳入空闲内存管理  

3. 但是拷贝时触发异常的地址肯定是从`buddy system`临时分配出来的，所以怀疑其他模块又释放这块内存空间给伙伴系统  
panic时会进kdb，执行ftdump命令，抓到如下打印，根据地址可以看到确实是从伙伴系统临时分配出来，然后写入数据  
```
cp-11611     0.... 25260374us : __alloc_pages_nodemask: [4850] page 0xfffffe0000202000  // 又从buddy system分配出
cp-11611     0d... 25260378us+: p: (pagecache_get_page.part.57+0x12c/0x2f8 <- __alloc_pages_nodemask) page=0xfffffe0000202000
cp-11611     0.... 25260427us : iov_iter_copy_from_user_atomic: [978] pfn 0x10080, page 0xfffffe0000202000, kaddr 0xffff000010080000
cp-11611     0d... 25260430us : t: (__arch_copy_from_user+0x0/0xac0) to=0xffff000010080000
```

4. `Reserved memory: created CMA memory pool at 0x0000000010000000, size 8 MiB`  
这条打印显示cma模块指定内存区域`0x10000000 - 0x10080000`，和kernel code有重叠  
所以有理由怀疑是cma指定区域和kernel code部分物理内存空间重叠导致的

5. 系统初始化内存管理早期阶段memblock模块会给kernel code，kernel data等预留内存空间  
之后转交剩余空闲物理内存给伙伴系统`buddy system`，调用关系如下    
```
mm_init
  mem_init
    memblock_free_all
      free_low_memory_core_early  //  提交系统内存给 buddy system
        __free_memory_core
          __free_pages_memory(start_pfn, end_pfn);
            memblock_free_pages(pfn_to_page(start), start, order);
              __free_pages_core(page, order);
                __ClearPageReserved(p);
                set_page_count(p, 0);     // _refcount 为0
                __free_pages
                  free_the_page     
                    __free_pages_ok(page, order);
                      free_one_page(page_zone(page), page, pfn, order, migratetype);
                        set_page_order(page, order); // 设置PG_buddy 标记
```

6. `free_one_page`接口是提交内存给伙伴系统的必经之路，而 `0x10080000`对应的页帧号`0x10080`  
在`free_one_page`函数入口添加调试打印，如果page地址对应的pfn刚好是`0x10080`的话，就打印出调用栈     
抓到CMA模块释放异常地址所在内存空间给`buddy system`
```
[    0.416939] [__free_one_page 924] pfn 0x10080, page 0xfffffe0000202000
[    0.424583] CPU: 0 PID: 1 Comm: swapper/0 Not tainted 5.4.74 #1
[    0.431075] Hardware name: Rockchip RK3566 EVB2 LP4X V10 Board (DT)
[    0.437950] Call trace:
[    0.440730]  dump_backtrace+0x0/0x160
[    0.444743]  show_stack+0x1c/0x28
[    0.448368]  dump_stack+0xdc/0x13c
[    0.452097]  free_one_page+0x50c/0x510
[    0.456205]  free_unref_page_commit+0xf0/0xf8
[    0.460955]  free_unref_page+0x6c/0xb8
[    0.465061]  __free_pages+0x3c/0x50
[    0.468885]  free_contig_range+0x74/0xb8
[    0.473167]  alloc_contig_range+0x2a4/0x3b0
[    0.477745]  cma_alloc+0x13c/0x2e8
[    0.481473]  dma_alloc_from_contiguous+0x44/0x50
[    0.486539]  dma_atomic_pool_init+0x6c/0x228
[    0.491185]  do_one_initcall+0x68/0x260
[    0.495372]  kernel_init_freeable+0x1fc/0x2b0
[    0.500148]  kernel_init+0x18/0x14c
[    0.503971]  ret_from_fork+0x10/0x18
```

7. 指定cma区域有两种方式，一种是dts保留内存节点，一种是内核传参指定起始地址和大小`cma=size@start_addr`  
当前问题用的是dts方式   
```
linux,cma {
        compatible = "shared-dma-pool";
        inactive;
        reusable;
        reg = <0x00 0x10000000 0x00 0x800000>;   //  0x10000000  - 0x10800000 , cma区域
        linux,cma-default;
};
```

8. 所以去掉dts里linux-cma节点，让内核自己选择cma起始位置和大小，拷贝大文件不会再出问题。

### 问题探究
为什么内核允许dts cma指定区域和文本段重叠，没有做重叠检查吗？  

如果检查到有重叠是不是应该保留失败，打印告警信息，或者内核自己选择一块空闲内存给cma模块。

```
start_kernel
	setup_arch
	arch_call_rest_init

setup_arch
	arm64_memblock_init
		memblock_reserve(__pa_symbol(_text), _end - _text);   // 先于dts模块保留部分内存区域
		early_init_fdt_scan_reserved_mem
			of_scan_flat_dt
				__fdt_scan_reserved_mem
					__reserved_mem_reserve_reg
						early_init_dt_reserve_memory_arch  // 这里添加所有保留区域重叠检测并没有效果，因为cma的reserve记录还在reserve_mems数组中保留着，后续还会调用rmem_cma_setup
			fdt_init_reserved_mem
				__rmem_check_for_overlap    // 只是针对dts中提取的所有保留区域之间的重叠检查，不包括kernel code reserve区域
				__reserved_mem_init_node
					initfn(rmem);    // cma节点对应回调函数rmem_cma_setup
		dma_contiguous_reserve(arm64_dma_phys_limit);
			dma_contiguous_reserve_area // 如果dts里没有linux,cma节点，那么内核要么自己选择一块区域(fixed==false)，要么根据内核参数cma=size@addr选定一块区域(此时fixed==true)
				cma_declare_contiguous
					cma_init_reserved_mem  //  注册记录cma内存区域

arch_call_rest_init
	rest_init
		kernel_init
			do_one_initcall
				cma_init_reserved_areas
					init_cma_reserved_pageblock
						__free_pages   // cma内存区域释放给伙伴系统
```

##### rmem_cma_setup
该函数里添加重叠检测最合适不过，但是还涉及到返回值检测，以及这块cma区域是否应该释放的问题。  

1. 如果dts里指定区域和kernel code空间重叠，那么返回EBUSY，但是指定的这块区域缺不应该memblock_free掉  
因为会进入buddy system，后续可能会分配出去，就会触发panic

2. 如果dts里指定区域没有和kernel code发生重叠，但是存在其它问题，返回了EINVAL，那么这块区域应该memblock_free掉  
进入buddy system，这样可以纳入系统内存管理

人为因素导致的这种情况，逻辑处理给出明确的告警提示即可，没必要过度解读处理。

```
static int __init rmem_cma_setup(struct reserved_mem *rmem)
{
	phys_addr_t align = PAGE_SIZE << max(MAX_ORDER - 1, pageblock_order);
	phys_addr_t mask = align - 1;
	unsigned long node = rmem->fdt_node;
	struct cma *cma;
	int err;

	if (!of_get_flat_dt_prop(node, "reusable", NULL) ||
	    of_get_flat_dt_prop(node, "no-map", NULL))
		return -EINVAL;

    if (memblock_is_region_reserved(rmem->base, rmem->size)) {  // 重叠检测，自己加的
  		pr_info("Reserved memory: overlap with existing one\n");
  		return -EBUSY;
  	}

	if ((rmem->base & mask) || (rmem->size & mask)) {
		pr_err("Reserved memory: incorrect alignment of CMA region\n");
		return -EINVAL;
	}

	err = cma_init_reserved_mem(rmem->base, rmem->size, 0, rmem->name, &cma);
	if (err) {
		pr_err("Reserved memory: unable to setup CMA region\n");
		return err;
	}
	/* Architecture specific contiguous memory fixup. */
	dma_contiguous_early_fixup(rmem->base, rmem->size);

	if (of_get_flat_dt_prop(node, "linux,cma-default", NULL))
		dma_contiguous_set_default(cma);

	rmem->ops = &rmem_cma_ops;
	rmem->priv = cma;

	pr_info("Reserved memory: created CMA memory pool at %pa, size %ld MiB\n",
		&rmem->base, (unsigned long)rmem->size / SZ_1M);

	return 0;
}
```

##### res_mem_init_node
cma模块对应的initfn回调函数即为rmem_cma_setup

```
res_mem_init_node() - call region specific reserved memory init code

static int __init __reserved_mem_init_node(struct reserved_mem *rmem)
{
	extern const struct of_device_id __reservedmem_of_table[];
	const struct of_device_id *i;
	int ret = -ENOENT;

	for (i = __reservedmem_of_table; i < &__rmem_of_table_sentinel; i++) {
		reservedmem_of_init_fn initfn = i->data;
		const char *compat = i->compatible;

		if (!of_flat_dt_is_compatible(rmem->fdt_node, compat))
			continue;

		ret = initfn(rmem);   // 调用各个保留区域对应的回调(cma对应rmem_cam_setup)
		if (ret == 0) {
			pr_info("initialized node %s, compatible id %s\n",
				rmem->name, compat);
			break;
		}
	}
	return ret;
}
```

##### fdt_init_reserved_mem
```
void __init fdt_init_reserved_mem(void)
{
	int i;

	/* check for overlapping reserved regions */
	__rmem_check_for_overlap();

	for (i = 0; i < reserved_mem_count; i++) {
		struct reserved_mem *rmem = &reserved_mem[i];
		unsigned long node = rmem->fdt_node;
		int len;
		const __be32 *prop;
		int err = 0;
		int nomap;

		nomap = of_get_flat_dt_prop(node, "no-map", NULL) != NULL;
		prop = of_get_flat_dt_prop(node, "phandle", &len);
		if (!prop)
			prop = of_get_flat_dt_prop(node, "linux,phandle", &len);
		if (prop)
			rmem->phandle = of_read_number(prop, len/4);

		if (rmem->size == 0)
			err = __reserved_mem_alloc_size(node, rmem->name,
						 &rmem->base, &rmem->size);
		if (err == 0) {
			err = __reserved_mem_init_node(rmem);  // rmem_cma_setup可能返回0，也可能返回EINVAL、EBUSY
			if (err != 0 && err != -ENOENT) {
				pr_info("node %s compatible matching fail\n",
					rmem->name);
				memblock_free(rmem->base, rmem->size);
				if (nomap)
					memblock_add(rmem->base, rmem->size);
			}
		}
	}
}
```

### 总结
首先，cma区域保留成功，模块本身初始化好之后，会释放本区域内存到buddy system供其它模块使用，一旦有大块内存需求的时候再回收回来

dts里添加的linux,cma指定的内存区域和kernel code内存段有部分重叠，但是内核缺乏重叠检测机制

`__rmem_check_for_overlap`只检查`reserved_mem`数组相邻元素内存区域之间是否有重叠，有的话打印告警，仅此而已

重叠检查并不检查这些区域和`arm64_memblock_init`中已经`memblock_reserve`下来的kernel code内存区域是否有重叠

在cma区域内存还保留在buddy system的时候，设备上执行大文件拷贝  

内存压力较大的时候就会从cma释放的区域申请内存(`__alloc_pages`)，并写入数据  

因为和kernel code重叠，该kernel code内存又是只读的，所以会触发异常   
`Unable to handle kernel write to read-only memory at virtual address ffff000010080000`  


### 参考
[linux-5.4.74](https://elixir.bootlin.com/linux/v5.4.74/source)  
[CMA模块学习笔记](http://www.wowotech.net/memory_management/cma.html)
