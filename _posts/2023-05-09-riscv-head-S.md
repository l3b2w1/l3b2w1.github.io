---
layout:     post
title:      riscv启动
subtitle:   riscv内核启动早期代码走读
date:       2023-05-09
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - riscv
---

# arch/riscv/kernel/head.S

arch/riscv/kernel/head.S 是 RISC-V架构Linux内核的一个汇编语言源文件，其作用是初始化内核和启动CPU。  

具体来说，head.S包含了以下几个主要的功能：

1. 设置栈顶指针。在RISC-V架构中，栈顶指针存储在寄存器sp中。head.S将sp设置为内核栈的起始地址，这是内核使用的栈空间。

2. 设置异常向量表。RISC-V架构中，异常向量表存储在固定的内存地址中，head.S会将异常向量表的地址存储到寄存器中，以便处理异常时能够正确地跳转到对应的异常处理程序。

3. 初始化内存管理。head.S会将物理内存映射到虚拟内存，设置内存保护机制等。

4. 启动CPU。head.S最后调用start_kernel函数启动内核。

基于内核版本v6.2  
https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/?h=v6.2

```
/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (C) 2012 Regents of the University of California
 */

#include <asm/asm-offsets.h>
#include <asm/asm.h>
#include <linux/init.h>
#include <linux/linkage.h>
#include <asm/thread_info.h>
#include <asm/page.h>
#include <asm/pgtable.h>
#include <asm/csr.h>
#include <asm/cpu_ops_sbi.h>
#include <asm/hwcap.h>
#include <asm/image.h>
#include <asm/xip_fixup.h>
#include "efi-header.S"

__HEAD
ENTRY(_start)
	/*
	 * Image header expected by Linux boot-loaders. The image header data
	 * structure is described in asm/image.h.
	 * Do not modify it without modifying the structure and all bootloaders
	 * that expects this header format!!
	 */
#ifdef CONFIG_EFI
	/*
	 * This instruction decodes to "MZ" ASCII required by UEFI.
	 */
	c.li s4,-13
	j _start_kernel
#else
	/* jump to start kernel */
	j _start_kernel
	/* reserved */
	.word 0
#endif
	.balign 8
#ifdef CONFIG_RISCV_M_MODE
	/* Image load offset (0MB) from start of RAM for M-mode */
	.dword 0
#else
#if __riscv_xlen == 64
	/* Image load offset(2MB) from start of RAM */
	.dword 0x200000
#else
	/* Image load offset(4MB) from start of RAM */
	.dword 0x400000
#endif
#endif
	/* Effective size of kernel image */
	.dword _end - _start
	.dword __HEAD_FLAGS
	.word RISCV_HEADER_VERSION
	.word 0
	.dword 0
	.ascii RISCV_IMAGE_MAGIC
	.balign 4
	.ascii RISCV_IMAGE_MAGIC2
#ifdef CONFIG_EFI
	.word pe_head_start - _start
pe_head_start:

	__EFI_PE_HEADER
#else
	.word 0
#endif

.align 2
#ifdef CONFIG_MMU
	.global relocate_enable_mmu
relocate_enable_mmu:
	/* Relocate return address */
	la a1, kernel_map                             // kernel_map全局变量的地址加载到a1
	XIP_FIXUP_OFFSET a1
	REG_L a1, KERNEL_MAP_VIRT_ADDR(a1)         // kernel_map.virt_addr 虚拟地址 KERNEL_LINK_ADDR加载到a1  
	la a2, _start                              // _start的物理地址加载到a2
	sub a1, a1, a2                          // a1 = a1 - a2      获取相对偏移
	add ra, ra, a1                           // ra = ra + a1     ra 虚拟地址 mmu使能之后要求ra为虚拟地址

	/* Point stvec to virtual address of intruction after satp write */  // satp CSR存放页表基地址
	la a2, 1f                                               //  标签1f物理地址存入a2
	add a2, a2, a1                                         // a2 加上偏移变成了虚拟地址
	csrw CSR_TVEC, a2                                           // a2 内容写入stvec向量基址寄存器，包括向量基址和向量模式

	/* Compute satp for kernel page tables, but don't load it yet */
	srl a2, a0, PAGE_SHIFT         //   a2 = a0 >> PAGE_SHIFT    a2就是early_pg_dir 的PPN
	la a1, satp_mode                //   satp_mode内存地址加载到 a1
	REG_L a1, 0(a1)                  // satp_mode的值加载到a1
	or a2, a2, a1                      // a2= a2 | a1    PPN或上satp mode组装成完整字段  

	/*
	 * Load trampoline page directory, which will cause us to trap to
	 * stvec if VA != PA, or simply fall through if VA == PA.  We need a
	 * full fence here because setup_vm() just wrote these PTEs and we need
	 * to ensure the new translations are in use.
	 */
	la a0, trampoline_pg_dir
	XIP_FIXUP_OFFSET a0
	srl a0, a0, PAGE_SHIFT   // 逻辑右移后a0里就是PPN
	or a0, a0, a1                 // a0 = a0 | a1  PPN或上satp mode组装成完整字段
	sfence.vma                // 刷新cache，写回内存
	csrw CSR_SATP, a0     // a0写入CSR_SATP，开启分页，触发异常；1f的虚拟地址已经写入了STVEC，所以触发异常直接跳转到1f虚拟地址，相当于从1f地址处的指令开始 PC 指向的就是虚拟地址了；切换到trampoline_pg_dir软件模拟的mmu
.align 2           // 2^2 4字节对齐
1:
	/* Set trap vector to spin forever to help debug */  // 以虚拟地址执行，MMU通过trampoline_pg_dir转换地址
	la a0, .Lsecondary_park
	csrw CSR_TVEC, a0             // secondary_park写入 CSR_TVEC

	/* Reload the global pointer */
.option push
.option norelax
	la gp, __global_pointer$
.option pop

	/*
	 * Switch to kernel page tables.  A full fence is necessary in order to
	 * avoid using the trampoline translations, which are only correct for
	 * the first superpage.  Fetching the fence is guaranteed to work
	 * because that first superpage is translated the same way.
	 */
	csrw CSR_SATP, a2    // a2 就是以early_pg_dir为页表基址   MMU开始通过early_pg_dir转换地址
	sfence.vma    // 通知处理器，软件可能已经修改了页表，处理器可以刷新TLB

	ret
#endif /* CONFIG_MMU */
#ifdef CONFIG_SMP
	.global secondary_start_sbi     // 启动其它cpu
secondary_start_sbi:
	/* Mask all interrupts */
	csrw CSR_IE, zero
	csrw CSR_IP, zero

	/* Load the global pointer */
	.option push
	.option norelax
		la gp, __global_pointer$
	.option pop

	/*
	 * Disable FPU to detect illegal usage of
	 * floating point in kernel space
	 */
	li t0, SR_FS
	csrc CSR_STATUS, t0

	/* Set trap vector to spin forever to help debug */
	la a3, .Lsecondary_park
	csrw CSR_TVEC, a3

	/* a0 contains the hartid & a1 contains boot data */
	li a2, SBI_HART_BOOT_TASK_PTR_OFFSET
	XIP_FIXUP_OFFSET a2
	add a2, a2, a1
	REG_L tp, (a2)
	li a3, SBI_HART_BOOT_STACK_PTR_OFFSET
	XIP_FIXUP_OFFSET a3
	add a3, a3, a1
	REG_L sp, (a3)

.Lsecondary_start_common:

#ifdef CONFIG_MMU
	/* Enable virtual memory and relocate to virtual address */
	la a0, swapper_pg_dir
	XIP_FIXUP_OFFSET a0
	call relocate_enable_mmu  // 开启mmu
#endif
	call setup_trap_vector
	tail smp_callin
#endif /* CONFIG_SMP */

.align 2
setup_trap_vector:
	/* Set trap vector to exception handler */
	la a0, handle_exception        // 异常向量寄存器写入真正的handler handle_exception
	csrw CSR_TVEC, a0

	/*
	 * Set sup0 scratch register to 0, indicating to exception vector that
	 * we are presently executing in kernel.
	 */
	csrw CSR_SCRATCH, zero
	ret

.align 2
.Lsecondary_park:  // 如果不支持SMP， 则其它harts 全部进入死循环
	/* We lack SMP support or have too many harts, so park this hart */
	wfi
	j .Lsecondary_park

END(_start)

ENTRY(_start_kernel)
	/* Mask all interrupts */   //先关闭中断
	csrw CSR_IE, zero
	csrw CSR_IP, zero

	/* Load the global pointer */   // 设置gp指向GOT
.option push
.option norelax
	la gp, __global_pointer$
.option pop

	/*
	 * Disable FPU to detect illegal usage of
	 * floating point in kernel space    // 清零CSR_STATUS的浮点位，禁浮点，也就是t0中标记1的位
	 */   
	li t0, SR_FS                            //   _AC(0x00006000, UL)     
	csrc CSR_STATUS, t0              // /* Floating-point Status，就是 CSR_SSTATUS */
#ifdef CONFIG_RISCV_BOOT_SPINWAIT   // 一般不会开启该配置项，所以boot会把启动核id号放到a0寄存器
	li t0, CONFIG_NR_CPUS
	blt a0, t0, .Lgood_cores
	tail .Lsecondary_park
.Lgood_cores:

	/* The lottery system is only required for spinwait booting method */
	/* Pick one hart to run the main boot sequence */
	la a3, hart_lottery        // 加载hart_lottery内存地址到a3寄存器
	li a2, 1
	amoadd.w a3, a2, (a3)    // a3内存中的数值原子加1，并且把旧的数值存入a3
	bnez a3, .Lsecondary_start        // a3为0，表示启动核，继续执行；否则跳转到Secondary_start

#endif /* CONFIG_RISCV_BOOT_SPINWAIT */

#ifndef CONFIG_XIP_KERNEL         // 清零BSS段
	/* Clear BSS for flat non-ELF images */
	la a3, __bss_start
	la a4, __bss_stop
	ble a4, a3, clear_bss_done
clear_bss:
	REG_S zero, (a3)
	add a3, a3, RISCV_SZPTR
	blt a3, a4, clear_bss
clear_bss_done:
#endif
	/* Save hart ID and DTB physical address */ //a0, a1都是bootloader传递过来的
	mv s0, a0                               // a0记录着bootloader启动核id 号
	mv s1, a1                             // a1记录着dtb起始地址

	la a2, boot_cpu_hartid          // boot_cpu_hartid 地址加载到a2寄存器
	XIP_FIXUP_OFFSET a2
	REG_S a0, (a2)                       // a0 保存到内存变量boot_cpu_hartid

	/* Initialize page tables and relocate to virtual addresses */
	la tp, init_task
	la sp, init_thread_union + THREAD_SIZE    // 临时内核栈
	XIP_FIXUP_OFFSET sp
#ifdef CONFIG_BUILTIN_DTB
	la a0, __dtb_start
	XIP_FIXUP_OFFSET a0
#else
	mv a0, s1                                   //设置 setup_vm 参数，也就是dtb起始地址
#endif /* CONFIG_BUILTIN_DTB */
	call setup_vm                                   // setup_vm 初始化临时页表
#ifdef CONFIG_MMU
	la a0, early_pg_dir
	XIP_FIXUP_OFFSET a0
	call relocate_enable_mmu         // 使能mmu
#endif /* CONFIG_MMU */

	call setup_trap_vector               // 设置trap
	/* Restore C environment */      // 恢复c执行环境
	la tp, init_task
	la sp, init_thread_union + THREAD_SIZE

#ifdef CONFIG_KASAN
	call kasan_early_init
#endif
	/* Start the kernel */    //启动内核
	call soc_early_init
	tail start_kernel          // 调用 C语言start_kernel

#ifdef CONFIG_RISCV_BOOT_SPINWAIT
.Lsecondary_start:
	/* Set trap vector to spin forever to help debug */
	la a3, .Lsecondary_park
	csrw CSR_TVEC, a3

	slli a3, a0, LGREG
	la a1, __cpu_spinwait_stack_pointer
	XIP_FIXUP_OFFSET a1
	la a2, __cpu_spinwait_task_pointer
	XIP_FIXUP_OFFSET a2
	add a1, a3, a1
	add a2, a3, a2

	/*
	 * This hart didn't win the lottery, so we wait for the winning hart to
	 * get far enough along the boot process that it should continue.
	 */
.Lwait_for_cpu_up:
	/* FIXME: We should WFI to save some energy here. */
	REG_L sp, (a1)
	REG_L tp, (a2)
	beqz sp, .Lwait_for_cpu_up
	beqz tp, .Lwait_for_cpu_up
	fence

	tail .Lsecondary_start_common
#endif /* CONFIG_RISCV_BOOT_SPINWAIT */

END(_start_kernel)

引导linux 内核的话，就不会开启 CONFIG_RISCV_M_MODE
```

# setup_vm
setup_vm 负责创建临时页表  
```
static void __init create_kernel_page_table(pgd_t *pgdir, bool early)
{
	uintptr_t va, end_va;

	end_va = kernel_map.virt_addr + kernel_map.size;  // size = _end - _start
	for (va = kernel_map.virt_addr; va < end_va; va += PMD_SIZE)
		create_pgd_mapping(pgdir, va,
				   kernel_map.phys_addr + (va - kernel_map.virt_addr),
				   PMD_SIZE,
				   early ?
					PAGE_KERNEL_EXEC : pgprot_from_va(va));
}

#define KERNEL_LINK_ADDR        (ADDRESS_SPACE_END - SZ_2G + 1)

asmlinkage void __init setup_vm(uintptr_t dtb_pa)
{
	pmd_t __maybe_unused fix_bmap_spmd, fix_bmap_epmd;

	kernel_map.virt_addr = KERNEL_LINK_ADDR; // 链接时指定的vmlinux镜像所在物理起始位置对应的虚拟地址
	kernel_map.page_offset = _AC(CONFIG_PAGE_OFFSET, UL); //PAGE_OFFSET就是kernel起始物理地址对应的虚拟地址

#ifdef CONFIG_XIP_KERNEL
	kernel_map.xiprom = (uintptr_t)CONFIG_XIP_PHYS_ADDR;
	kernel_map.xiprom_sz = (uintptr_t)(&_exiprom) - (uintptr_t)(&_xiprom);

	phys_ram_base = CONFIG_PHYS_RAM_BASE;
	kernel_map.phys_addr = (uintptr_t)CONFIG_PHYS_RAM_BASE;
	kernel_map.size = (uintptr_t)(&_end) - (uintptr_t)(&_sdata);

	kernel_map.va_kernel_xip_pa_offset = kernel_map.virt_addr - kernel_map.xiprom;
#else
	kernel_map.phys_addr = (uintptr_t)(&_start); // vmlinux加载的实际物理地址
	kernel_map.size = (uintptr_t)(&_end) - kernel_map.phys_addr; // vmlinux大小
#endif

#if defined(CONFIG_64BIT) && !defined(CONFIG_XIP_KERNEL)
	set_satp_mode();
#endif
	// 这意思是内核镜像映射到了两处不同的虚拟地址  这两处虚拟地址指向同一个物理位置
	// va_pa_offset用于线性映射，va_kernel_pa_offset 用于非线性映射
	kernel_map.va_pa_offset = PAGE_OFFSET - kernel_map.phys_addr;
	kernel_map.va_kernel_pa_offset = kernel_map.virt_addr - kernel_map.phys_addr;

	riscv_pfn_base = PFN_DOWN(kernel_map.phys_addr);

	/*
	 * The default maximal physical memory size is KERN_VIRT_SIZE for 32-bit
	 * kernel, whereas for 64-bit kernel, the end of the virtual address
	 * space is occupied by the modules/BPF/kernel mappings which reduces
	 * the available size of the linear mapping.
	 */
	memory_limit = KERN_VIRT_SIZE - (IS_ENABLED(CONFIG_64BIT) ? SZ_4G : 0);

	/* Sanity check alignment and size */
	/*检查PAGE_OFFSET是否1G对齐，以及kernel入口地址是否2M对齐*/
	BUG_ON((PAGE_OFFSET % PGDIR_SIZE) != 0);
	BUG_ON((kernel_map.phys_addr % PMD_SIZE) != 0);

#ifdef CONFIG_64BIT
	/*
	 * The last 4K bytes of the addressable memory can not be mapped because
	 * of IS_ERR_VALUE macro.
	 */
	BUG_ON((kernel_map.virt_addr + kernel_map.size) > ADDRESS_SPACE_END - SZ_4K);
#endif

	apply_early_boot_alternatives();
	pt_ops_set_early();

	/* Setup early PGD for fixmap */ // 构造fixmap的early PGD表项
	create_pgd_mapping(early_pg_dir, FIXADDR_START,
			   fixmap_pgd_next, PGDIR_SIZE, PAGE_TABLE);

#ifndef __PAGETABLE_PMD_FOLDED
/* here not def __PAGETABLE_PMD_FOLDED */
	/* Setup fixmap P4D and PUD */
	if (pgtable_l5_enabled)
		create_p4d_mapping(fixmap_p4d, FIXADDR_START,
				   (uintptr_t)fixmap_pud, P4D_SIZE, PAGE_TABLE);
	/* Setup fixmap PUD and PMD */
	if (pgtable_l4_enabled)
		create_pud_mapping(fixmap_pud, FIXADDR_START,
				   (uintptr_t)fixmap_pmd, PUD_SIZE, PAGE_TABLE);
	// fixmap总大小2M，到PMD级别就够了
	create_pmd_mapping(fixmap_pmd, FIXADDR_START,
			   (uintptr_t)fixmap_pte, PMD_SIZE, PAGE_TABLE);

	/* Setup trampoline PGD and PMD 为vmlinux创建蹦床临时映射*/
	create_pgd_mapping(trampoline_pg_dir, kernel_map.virt_addr,
			   trampoline_pgd_next, PGDIR_SIZE, PAGE_TABLE);
	if (pgtable_l5_enabled)
		create_p4d_mapping(trampoline_p4d, kernel_map.virt_addr,
				   (uintptr_t)trampoline_pud, P4D_SIZE, PAGE_TABLE);
	if (pgtable_l4_enabled)
		create_pud_mapping(trampoline_pud, kernel_map.virt_addr,
				   (uintptr_t)trampoline_pmd, PUD_SIZE, PAGE_TABLE);
#ifdef CONFIG_XIP_KERNEL
	create_pmd_mapping(trampoline_pmd, kernel_map.virt_addr,
			   kernel_map.xiprom, PMD_SIZE, PAGE_KERNEL_EXEC);
#else
	/* 为vmlinux创建PMD映射,填充临时页表项 */
	create_pmd_mapping(trampoline_pmd, kernel_map.virt_addr,
			   kernel_map.phys_addr, PMD_SIZE, PAGE_KERNEL_EXEC);
#endif
#else
	/* Setup trampoline PGD */
	create_pgd_mapping(trampoline_pg_dir, kernel_map.virt_addr,
			   kernel_map.phys_addr, PGDIR_SIZE, PAGE_KERNEL_EXEC);
#endif

	/*
	 * Setup early PGD covering entire kernel which will allow
	 * us to reach paging_init(). We map all memory banks later
	 * in setup_vm_final() below.
	 */
	// 只为vmlinux大小的内核镜像创建启动早期页表项，early非线性映射
	create_kernel_page_table(early_pg_dir, true);

	/* Setup early mapping for FDT early scan FDT早期页表项 early非线性映射 */
	create_fdt_early_page_table(early_pg_dir, dtb_pa);

	/*
	 * Bootime fixmap only can handle PMD_SIZE mapping. Thus, boot-ioremap
	 * range can not span multiple pmds.
	 */
	BUG_ON((__fix_to_virt(FIX_BTMAP_BEGIN) >> PMD_SHIFT)
		     != (__fix_to_virt(FIX_BTMAP_END) >> PMD_SHIFT));

#ifndef __PAGETABLE_PMD_FOLDED
/* here : not def __PAGETABLE_PMD_FOLDED */
	/*
	 * Early ioremap fixmap is already created as it lies within first 2MB
	 * of fixmap region. We always map PMD_SIZE. Thus, both FIX_BTMAP_END
	 * FIX_BTMAP_BEGIN should lie in the same pmd. Verify that and warn
	 * the user if not.
	 */
	fix_bmap_spmd = fixmap_pmd[pmd_index(__fix_to_virt(FIX_BTMAP_BEGIN))];
	fix_bmap_epmd = fixmap_pmd[pmd_index(__fix_to_virt(FIX_BTMAP_END))];
	if (pmd_val(fix_bmap_spmd) != pmd_val(fix_bmap_epmd)) {
		WARN_ON(1);
		pr_warn("fixmap btmap start [%08lx] != end [%08lx]\n",
			pmd_val(fix_bmap_spmd), pmd_val(fix_bmap_epmd));
		pr_warn("fix_to_virt(FIX_BTMAP_BEGIN): %08lx\n",
			fix_to_virt(FIX_BTMAP_BEGIN));
		pr_warn("fix_to_virt(FIX_BTMAP_END):   %08lx\n",
			fix_to_virt(FIX_BTMAP_END));

		pr_warn("FIX_BTMAP_END:       %d\n", FIX_BTMAP_END);
		pr_warn("FIX_BTMAP_BEGIN:     %d\n", FIX_BTMAP_BEGIN);
	}
#endif

	pt_ops_set_fixmap();

}
```
# setup_arch
```
setup_arch
	parse_dtb    // 架构相关
	setup_initial_init_mm(_stext, _etext, _edata, _end); // 架构无关
	early_ioremap_setup    // 架构无关
	jump_label_init    // 架构无关
	efi_init       // 架构无关
	paging_init    // 架构相关
      setup_bootmem
      setup_vm_final
```
### paging_init
paging_init 初始化swapper_pg_dir 页表，全面启用MMU分页机制

##### setup_bootmem
```
/*
 * vmlinux、initrd所在区域保留
 * 确定min_low_pfn、max_low_pfn、high_memory
 * dtb区域保留
 * dma区域保留
 * cma区域保留
 */
static void __init setup_bootmem(void)
{
	// _end非线性地址 vmlinux = _end - kernel_map.va_kernel_pa_offset
	phys_addr_t vmlinux_end = __pa_symbol(&_end);

	phys_addr_t max_mapped_addr;
	phys_addr_t phys_ram_end, vmlinux_start;

	if (IS_ENABLED(CONFIG_XIP_KERNEL))
		vmlinux_start = __pa_symbol(&_sdata);
	else
		vmlinux_start = __pa_symbol(&_start);

	// 限制物理内存大小
	memblock_enforce_memory_limit(memory_limit);

	/*
	 * Make sure we align the reservation on PMD_SIZE since we will
	 * map the kernel in the linear mapping as read-only: we do not want
	 * any allocation to happen between _end and the next pmd aligned page.
	 */ // PMD_SIZE 2M大小对齐
	if (IS_ENABLED(CONFIG_64BIT) && IS_ENABLED(CONFIG_STRICT_KERNEL_RWX))
		vmlinux_end = (vmlinux_end + PMD_SIZE - 1) & PMD_MASK;
	/*
	 * Reserve from the start of the kernel to the end of the kernel
	 */
	/* memblock保留vmlinux 所在内存区域, 并且2M对齐*/
	memblock_reserve(vmlinux_start, vmlinux_end - vmlinux_start);

	// memblock记录的最后一个内存区块的结束物理地址
	phys_ram_end = memblock_end_of_DRAM();
	if (!IS_ENABLED(CONFIG_XIP_KERNEL))
		phys_ram_base = memblock_start_of_DRAM(); //memblock记录的第一个内存区块的起始物理地址

	/*
	 * memblock allocator is not aware of the fact that last 4K bytes of
	 * the addressable memory can not be mapped because of IS_ERR_VALUE
	 * macro. Make sure that last 4k bytes are not usable by memblock
	 * if end of dram is equal to maximum addressable memory.  For 64-bit
	 * kernel, this problem can't happen here as the end of the virtual
	 * address space is occupied by the kernel mapping then this check must
	 * be done as soon as the kernel mapping base address is determined.
	 */
	if (!IS_ENABLED(CONFIG_64BIT)) {
		max_mapped_addr = __pa(~(ulong)0);
		if (max_mapped_addr == (phys_ram_end - 1))
			memblock_set_current_limit(max_mapped_addr - 4096);
	}

	min_low_pfn = PFN_UP(phys_ram_base);
	max_low_pfn = max_pfn = PFN_DOWN(phys_ram_end);
	high_memory = (void *)(__va(PFN_PHYS(max_low_pfn)));

	// dma32物理内存限制4G大小
	dma32_phys_limit = min(4UL * SZ_1G, (unsigned long)PFN_PHYS(max_low_pfn));
	set_max_mapnr(max_low_pfn - ARCH_PFN_OFFSET);

	reserve_initrd_mem();
	/*
	 * If DTB is built in, no need to reserve its memblock.
	 * Otherwise, do reserve it but avoid using
	 * early_init_fdt_reserve_self() since __pa() does
	 * not work for DTB pointers that are fixmap addresses
	 */
	if (!IS_ENABLED(CONFIG_BUILTIN_DTB)) {
		/*
		 * In case the DTB is not located in a memory region we won't
		 * be able to locate it later on via the linear mapping and
		 * get a segfault when accessing it via __va(dtb_early_pa).
		 * To avoid this situation copy DTB to a memory region.
		 * Note that memblock_phys_alloc will also reserve DTB region.
		 */
		if (!memblock_is_memory(dtb_early_pa)) {
			size_t fdt_size = fdt_totalsize(dtb_early_va);
			phys_addr_t new_dtb_early_pa = memblock_phys_alloc(fdt_size, PAGE_SIZE);
			void *new_dtb_early_va = early_memremap(new_dtb_early_pa, fdt_size);

			memcpy(new_dtb_early_va, dtb_early_va, fdt_size);
			early_memunmap(new_dtb_early_va, fdt_size);
			_dtb_early_pa = new_dtb_early_pa;
		} else
			memblock_reserve(dtb_early_pa, fdt_totalsize(dtb_early_va));  // dtb区域保留
	}

	// CONFIG_DMA_CMA CONFIG_CMA开启的情况下需要保留, 否则实现为空
	dma_contiguous_reserve(dma32_phys_limit);
	if (IS_ENABLED(CONFIG_64BIT))
		hugetlb_cma_reserve(PUD_SHIFT - PAGE_SHIFT);

	memblock_allow_resize();
}

```

##### setup_vm_final
创建并且启用swapper_pg_dir页表，为内核镜像建立映射
```
// 选择合适的映射大小，kernel入口地址2M对齐或者kernel大小能被2M整除时，map_size就是2M，否则就是4K。
static uintptr_t __init best_map_size(phys_addr_t base, phys_addr_t size)
{
	/* Upgrade to PMD_SIZE mappings whenever possible */
	base &= PMD_SIZE - 1;
	if (!base && size >= PMD_SIZE)
		return PMD_SIZE;

	return PAGE_SIZE;
}

static void __init setup_vm_final(void)
{
	uintptr_t va, map_size;
	phys_addr_t pa, start, end;
	u64 i;

	/* Setup swapper PGD for fixmap */
	create_pgd_mapping(swapper_pg_dir, FIXADDR_START,
			   __pa_symbol(fixmap_pgd_next),
			   PGDIR_SIZE, PAGE_TABLE);

	/* Map all memory banks in the linear mapping 为整个物理内存创建页表 */
	for_each_mem_range(i, &start, &end) {
		if (start >= end)
			break;
		if (start <= __pa(PAGE_OFFSET) &&
		    __pa(PAGE_OFFSET) < end)
			start = __pa(PAGE_OFFSET);
		if (end >= __pa(PAGE_OFFSET) + memory_limit)
			end = __pa(PAGE_OFFSET) + memory_limit;

		// 从PAGE_OFFSET位置开始建立线性映射, pa起始地址对应kerenl_map.phys_addr, map_size == 2M
		for (pa = start; pa < end; pa += map_size) {
			va = (uintptr_t)__va(pa);
			map_size = best_map_size(pa, end - pa);

			create_pgd_mapping(swapper_pg_dir, va, pa, map_size,
					   pgprot_from_va(va));
		}
	}

	/* Map the kernel: 为vmlinux建立非线性映射*/
	if (IS_ENABLED(CONFIG_64BIT))
		create_kernel_page_table(swapper_pg_dir, false);

#ifdef CONFIG_KASAN
	kasan_swapper_init();
#endif

	/* Clear fixmap PTE and PMD mappings */
	clear_fixmap(FIX_PTE);
	clear_fixmap(FIX_PMD);
	clear_fixmap(FIX_PUD);
	clear_fixmap(FIX_P4D);

	/* Move to swapper page table 使用swapper_pg_dir页表*/
	csr_write(CSR_SATP, PFN_DOWN(__pa_symbol(swapper_pg_dir)) | satp_mode);
	local_flush_tlb_all(); // sfence.vma刷新TLB

	pt_ops_set_late(); //
}
```


# qemu启动Image
qemu虚拟机启动riscv内核镜像，配置4G内存，SV57

qemu启动riscv系统之后进kdb查看
```
起始的64字节是RISCV Image的头
u32 code0;                /* Executable code */
u32 code1;                /* Executable code */
u64 text_offset;          /* Image load offset, little endian */
u64 image_size;           /* Effective Image size, little endian */
u64 flags;                /* kernel flags, little endian */
u32 version;              /* Version of this header */
u32 res1 = 0;             /* Reserved */
u64 res2 = 0;             /* Reserved */
u64 magic = 0x5643534952; /* Magic number, little endian, "RISCV" */
u32 magic2 = 0x05435352;  /* Magic number 2, little endian, "RSC\x05" */
u32 res3;                 /* Reserved for PE COFF offset */

[0]kdb> md4 0xffffffff80000000    // mmu非线性映射Image起始位置
0xffffffff80000000 106f5a4d 00010d20 00200000 00000000   MZo. ..... .....
0xffffffff80000010 011d3000 00000000 00000000 00000000   .0..............
0xffffffff80000020 00000002 00000000 00000000 00000000   ................
0xffffffff80000030 43534952 00000056 05435352 00000040   RISCV...RSC.@...   // magic magic2
0xffffffff80000040 00004550 00025064 00000000 00000000   PE..dP..........
0xffffffff80000050 00000000 020600a0 1402020b 009ff000   ................
0xffffffff80000060 007d3000 00000000 008340bc 00001000   .0}......@......
0xffffffff80000070 00000000 00000000 00001000 00000200   ................

[2]kdb> md4 0xff60000000000000   // 线性映射Image起始位置
0xff60000000000000 106f5a4d 00010d20 00200000 00000000   MZo. ..... .....
0xff60000000000010 011d3000 00000000 00000000 00000000   .0..............
0xff60000000000020 00000002 00000000 00000000 00000000   ................
0xff60000000000030 43534952 00000056 05435352 00000040   RISCV...RSC.@...   // magic magic2
0xff60000000000040 00004550 00025064 00000000 00000000   PE..dP..........
0xff60000000000050 00000000 020600a0 1402020b 009ff000   ................
0xff60000000000060 007d3000 00000000 00834266 00001000   .0}.....fB......
0xff60000000000070 00000000 00000000 00001000 00000200   ................

hexdump arch/riscv/boot/Image
0000000 5a4d 106f 0d20 0001 0000 0020 0000 0000
0000010 3000 011d 0000 0000 0000 0000 0000 0000
0000020 0002 0000 0000 0000 0000 0000 0000 0000
0000030 4952 4353 0056 0000 5352 0543 0040 0000
```

### virtual memory layout

##### RISC-V Linux Kernel SV57
SV57要求地址位63-57是第56位的副本，意即  
第56位为0时，63-57也都是0，代表用户态内存空间，起始地址为 0，结束地址为 00ffffffffffffff  
第56位为1时，63-57也都是1，代表内核态内存空间，起始地址为ff00000000000000，结束地址为 ffffffffffffffff   

二者之间有一个巨大的空洞 0100000000000000 - feffffffffffffff
```
========================================================================================================================
     Start addr    |   Offset   |     End addr     |  Size   | VM area description
========================================================================================================================
                   |            |                  |         |
  0000000000000000 |   0        | 00ffffffffffffff |   64 PB | user-space virtual memory, different per mm
 __________________|____________|__________________|_________|___________________________________________________________
                   |            |                  |         |
  0100000000000000 | +64     PB | feffffffffffffff | ~16K PB | ... huge, almost 64 bits wide hole of non-canonical
                   |            |                  |         | virtual memory addresses up to the -64 PB
                   |            |                  |         | starting offset of kernel mappings.
 __________________|____________|__________________|_________|___________________________________________________________
                                                             |
                                                             | Kernel-space virtual memory, shared between all processes:
 ____________________________________________________________|___________________________________________________________
                   |            |                  |         |
  ff1bfffffee00000 | -57     PB | ff1bfffffeffffff |    2 MB | fixmap     FIXADDR_START
  ff1bffffff000000 | -57     PB | ff1bffffffffffff |   16 MB | PCI io
  ff1c000000000000 | -57     PB | ff1fffffffffffff |    1 PB | vmemmap
  ff20000000000000 | -56     PB | ff5fffffffffffff |   16 PB | vmalloc/ioremap space
  ff60000000000000 | -40     PB | ffdeffffffffffff |   32 PB | direct mapping of all physical memory，ff60000000000000对应 PAGE_OFFSET，线性映射起始地址
  ffdf000000000000 |  -8     PB | fffffffeffffffff |    8 PB | kasan
 __________________|____________|__________________|_________|____________________________________________________________
                                                             |
                                                             | Identical layout to the 39-bit one from here on:
 ____________________________________________________________|____________________________________________________________
                   |            |                  |         |
  ffffffff00000000 |  -4     GB | ffffffff7fffffff |    2 GB | modules, BPF
  ffffffff80000000 |  -2     GB | ffffffffffffffff |    2 GB | kernel     内核镜像非线性映射起始地址
 __________________|____________|__________________|_________|____________________________________________________________

```

##### 内存相关全局变量

|全局变量|数值|说明|
|----|----|----|
|kernel_map.virt_addr|0xFFFFFFFF80000000|KERNEL_LINK_ADDR|
|kernel_map.page_offset|0xFF60000000000000|CONFIG_PAGE_OFFSET|
|memory_limit|0x7FFFFF00000000|物理地址空间大小限制|
|KERN_VIRT_SIZE|0x80000000000000|虚拟内存区域大小|
|FIXADDR_START|0xff1bfffffee00000|固定映射区域大小|
|pgtable_l4_enabled|1|四级页表使能|
|pgtable_l5_enabled|1|五级页表使能|



SV57代表启用5级页表，各级页表项管理覆盖的内存大小以512的倍数递增，即每一级页表都包含512个表项   

|宏|数值|说明|
|-----|----|----|
|PGDIR_SIZE|0x1000000000000|256T|
|P4D_SIZE|0x8000000000|512G|
|PUD_SIZE|0x40000000|1G|
|PMD_SIZE|0x200000|2M|

|宏|数值|
|-----|----|
|PTRS_PER_PGD |512|
|PTRS_PER_P4D	|512|
|PTRS_PER_PUD |512|
|PTRS_PER_PMD	|512|
|PTRS_PER_PTE	|512|

kernel_map.va_pa_offset便于pa和va之间快速转换
```
#define is_kernel_mapping(x)	\
	((x) >= kernel_map.virt_addr && (x) < (kernel_map.virt_addr + kernel_map.size))
#define is_linear_mapping(x)	\
((x) >= PAGE_OFFSET && (!IS_ENABLED(CONFIG_64BIT) || (x) < PAGE_OFFSET + KERN_VIRT_SIZE))
```

```
#define linear_mapping_pa_to_va(x)      ((void *)((unsigned long)(x) + kernel_map.va_pa_offset))
#define __pa_to_va_nodebug(x)           linear_mapping_pa_to_va(x)
#define __va(x)         ((void *)__pa_to_va_nodebug((phys_addr_t)(x)))
```

```
#define linear_mapping_va_to_pa(x)      ((unsigned long)(x) - kernel_map.va_pa_offset)
#define __va_to_pa_nodebug(x)	({						\
	unsigned long _x = x;							\
	is_linear_mapping(_x) ?							\
		linear_mapping_va_to_pa(_x) : kernel_mapping_va_to_pa(_x);	\
	})

#define __virt_to_phys(x)       __va_to_pa_nodebug(x)
#define __pa(x)         __virt_to_phys((unsigned long)(x))
```

