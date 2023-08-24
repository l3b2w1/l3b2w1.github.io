---
layout:     post
title:      riscv异常处理流程
subtitle:   riscv kernel handle exception
date:       2023-08-09
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - riscv
    - exception
    - kernel
---
### 异常简介
riscv架构上异常分为两类，同步异常和异步中断，二者均属于狭义上的具体的异常类型。     
这个从内核代码实现也可以看出来，中断和异常处理有统一入口`handle_excpetion` 。       
`handle_excpetion`会根据scause寄存器判断具体属于异常还是中断。  
后续所说异常统指这两种异常，除非明确指明是具体类型异常或者具体类型中断。   

**从功能上划分，riscv定义了三种类型的中断：软件中断、定时器中断和外部中断。**  
具体中断就必须谈及中断来源，这个涉及到riscv架构的CLINT和PLIC中断控制器。  

软件和定时器中断是由核心本地中断控制器（CLINT）生成的本地中断，直接路由到Hart。 系统中没有其他本地中断源。
全局中断由平台级中断控制器（PLIC）管理，通过外部中断源直接路由到Hart。  

默认情况下，所有中断都在机器模式下处理。对于支持监管者模式的Hart，可以选择性地将中断委托给监管者模式处理。  

本文只关注异常处理流程，暂不考虑中断来源，也不介绍具体的哪种异常或者中断。  

**异常委托**
> 默认情况下，任何特权级别上的所有异常和中断都在M模式下处理，M模式处理程序可以通过MRET指令将异常重定向回适当的特权级别     
为了提高性能，具体实现可以在medeleg和mideleg内提供单独的读/写位，以指示某些异常和中断应该由较低特权级别直接处理。  

这个涉及到M模式下异常委派寄存器（medeleg）和中断委派寄存器（mideleg）
可以参考[OpenSBI委派代码实现](https://l3b2w1.github.io/2023/07/03/opensbi-fw_base/#delegate_traps)  

### 异常处理流程
**linux系统运行时发生了异常，CPU会自动完成如下操作:**  
1. scause寄存器将被写入异常的原因；  
2. sepc寄存器将被写入触发异常的指令的虚拟地址；  
3. stval寄存器将被写入特定于异常的所访问的数据的虚拟内存地址；  
4. sstatus寄存器的SPP字段将被写入异常发生时的特权模式；  
5. sstatus寄存器的SPIE字段将被写入异常发生时SIE字段的值；  
6. sstatus寄存器的SIE字段清零，关闭异常；  
7. 设置特权模式为S模式，跳转到异常向量表，也就是把stvec的值直接赋给pc寄存器

**然后内核就进入了handle_excpetion处理流程**  
1. 把异常发生时打断的寄存器上下文保存到栈上  
2. 解析scause寄存器，判断是属于中断还是异常，适当跳转到相应的处理入口
3. 异常处理完毕返回时，把栈上保存的上下文恢复到各个寄存器
4. 执行sret指令，返回被异常打断的现场。

sret指令会把sstatus.SPIE字段设置到sstatus.SIE字段，恢复异常触发前的中断使能状态  
把sepc中的指令地址(或者sepc存储的指令的下一条指令)赋给PC寄存器

**异常返回地址的处理**  
如果是异步中断，返回下一条即将执行的指令  
如果是同步异常，可能返回触发异常的指令（比如page fault），也可能返回下一条指令（比如系统调用）

### 异常处理相关的S模式寄存器
内容和截图均摘录自特权模式指令集手册。    

##### stvec  
>stvec中的BASE字段是一个WARL字段，可以保存任何有效的虚拟或物理地址，但需要满足以下对齐约束：  
地址必须至少是4字节对齐，而MODE设置可能会对BASE字段中的值施加额外的对齐约束。  

>MODE字段的编码如表4.1所示。  
当MODE=Direct时，所有异常进入特权模式会导致将pc设置为BASE字段中的地址。  
当MODE=Vectored时，所有进入特权模式的同步异常会导致将pc设置为BASE字段中的地址，  
而中断会导致将pc设置为BASE字段中的地址加上中断原因编号的四倍。  
例如，特权模式的定时器中断（见表4.2）会导致pc被设置为BASE+0x14。  
设置MODE=Vectored可能会对BASE施加额外的对齐约束，要求最多4个XLEN字节的对齐。  

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2023-08-09-stvec.png)

##### stval

>stval寄存器是一个XLEN位的读写寄存器，格式如图4.10所示。  
当陷入到S模式时，stval寄存器被写入特定于异常的信息，以协助软件处理陷入。   
否则，stval寄存器不会被实现写入，尽管软件可以显式地进行写入。  
当触发硬件断点，或发生指令获取、加载、存储访问或页故障异常，或发生指令获取或AMO（原子内存操作）地址不对齐异常时，  
stval寄存器将被写入导致异常的地址。对于其他异常，stval将被设置为零，但未来的标准可能会重新定义stval在其他异常情况下的设置。

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2023-08-09-stval.png)

##### sepc
> sepc 是一个 XLEN 位的读/写寄存器，格式如图 4.8 所示。  
sepc（sepc[0]）的最低位始终为零。在不支持具有16位指令对齐的指令集扩展的实现中，低两位（sepc[1:0]）始终为零。  
sepc 是一个 WARL 寄存器，必须能够容纳所有有效的物理和虚拟地址。它无需能够容纳所有可能的无效地址。  
在写入 sepc 之前，实现可以将一些无效地址模式转换为其他无效地址。  
当陷入 S 模式时，sepc 被写入遇到异常的指令的虚拟地址。否则，实现不会写入 sepc，尽管软件可以显式地写入它。

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2023-08-09-sepc.png)

##### scause
系统发生异常时，cpu自动写入scause寄存器，最高位为1代表中断，为0代表异常

>scause寄存器是一个XLEN位的读写寄存器，格式如图4.9所示。  
当陷入到S模式时，scause寄存器被写入一个代码，表示导致陷入的事件。  
否则，scause寄存器不会被实现写入，尽管软件可以显式地进行写入。  
scause寄存器中的中断位在包含一个标识最后异常的代码时被设置。  
表4.2列出了当前监管模式ISA可能的异常代码，按优先级降序排列。  
异常代码是一个WLRL字段，因此只保证包含受支持的异常代码。  

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2023-08-09-scause.png)

##### sstatus
> sstatus寄存器是一个XLEN位的读写寄存器，用于跟踪处理器的当前操作状态。  
其格式如图4.1所示（适用于RV32），图4.2（适用于RV64和RV128）。  
SPP位指示hart在进入监管者模式之前所执行的特权级。  
当发生异常时，如果异常来源于用户模式，则SPP被设置为0；否则设置为1。    
当执行SRET指令从异常处理程序返回时，特权级将设置为用户模式（如果SPP位为0），或设置为监管者模式（如果SPP位为1）；然后，SPP被设置为0。
（注：这里的hart指的是硬件线程，XLEN是指RISC-V中整数寄存器的宽度，RV32为32位，RV64为64位，RV128为128位。）

> SIE位用于在监管者模式下启用或禁用所有中断。当SIE位为0时，在监管者模式下不会发生中断。  
当hart在用户模式下运行时，SIE寄存器的值被忽略，监管者级别的中断是启用的。  
监管者可以使用sie寄存器禁用单个中断源。  

> SPIE位指示在陷入监管者模式之前是否启用了监管者级别的中断。  
当发生异常进入监管者模式时，SPIE被设置为SIE的值，而SIE被设置为0，相当于关闭中断。  
当执行SRET指令时，SIE被设置为SPIE的值(恢复为异常发生前保存的SIE值)，然后SPIE被设置为1。  

> UIE位用于启用或禁用用户模式下的中断。只有当UIE位被设置且hart正在用户模式下运行时，用户级别的中断才会启用。  
UPIE位指示在发生用户级别的异常之前是否启用了用户级别的中断。  
当执行URET指令时，UIE被设置为UPIE的值，而UPIE被设置为1。用户级别的中断是可选的。如果省略，则UIE和UPIE位被硬连接为0。  

> SUM（允许监管者用户内存访问）位修改了S模式在访问虚拟内存时加载、存储和指令获取的特权。  
当SUM=0时，S模式对可被U模式访问的页面（如图4.15中的U=1）的内存访问将引发错误。  
当SUM=1时，这些访问是允许的。当基于页面的虚拟内存未生效或在U模式下执行时，SUM不产生效果。  
SUM机制防止监管软件无意中访问用户内存。操作系统可以在SUM未设置的情况下执行大部分代码；  
那些需要访问用户内存的少数代码段可以暂时设置SUM。

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2023-08-09-sstatus.png)

##### sip 和 sie

>sip寄存器是一个XLEN位的读写寄存器，包含有关待处理中断的信息，而sie寄存器是相应的XLEN位读写寄存器，包含中断使能位。  

> riscv定义了三种类型的中断：软件中断、定时器中断和外部中断。  
在当前hart上，通过向sip寄存器的supervisor software interrupt-pending (SSIP)位写入1，可以触发监管者级别的软件中断。  
pending的监管者级别软件中断可以通过将sip中的SSIP位写入0来清除。当sie寄存器的SSIE位为0时，监管者级别的软件中断被禁用。  
核间中断IPI通过SBI调用发送给其他harts，这最终将导致接收方hart的sip寄存器中的SSIP位被设置。  

> 在当前hart上，通过向sip寄存器的user software interrupt-pending (USIP)位写入1，可以触发用户级别的软件中断。  
pending的用户级别软件中断可以通过将sip中的USIP位写入0来清除。当sie寄存器的USIE位为0时，用户级别的软件中断被禁用。  
如果不支持用户级别中断，USIP和USIE将被硬连线为0。在sip寄存器中，除了SSIP、USIP和UEIP之外的所有位都是只读的。  

> 如果sip寄存器中的STIP位被设置，则表示挂起了监管者级别的定时器中断。  
当sie寄存器的STIE位为0时，监管者级别的定时器中断被禁用。可以使用SBI调用到SEE来清除挂起的定时器中断。

> 如果sip寄存器中的SEIP位被设置，则表示挂起了监管者级别的外部中断。  
当sie寄存器的SEIE位为0时，监管者级别的外部中断被禁用。SBI应该提供屏蔽、解除屏蔽和查询外部中断原因的功能。  

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2023-08-09-sip-sie.png)

### 异常处理相关代码
如下是qemu上一次串口中断的调用栈示例
```
[    5.462092] Hardware name: riscv-virtio,qemu (DT)
[    5.462991] Call Trace:
[    5.463427] [<ffffffff8000548e>] dump_backtrace+0x1c/0x24
[    5.464248] [<ffffffff8082ff6c>] show_stack+0x2c/0x38
[    5.465000] [<ffffffff8083b126>] dump_stack_lvl+0x3c/0x54
[    5.465802] [<ffffffff8083b152>] dump_stack+0x14/0x1c 
[    5.466537] [<ffffffff8044b4c2>] plic_handle_irq+0x54/0x11e  // 经由plic上报给cpu，全局中断
[    5.467369] [<ffffffff8005f82e>] generic_handle_domain_irq+0x1c/0x2a
[    5.468244] [<ffffffff8044b2d8>] riscv_intc_irq+0x2e/0x46    // 中断处理总入口
[    5.469018] [<ffffffff8083bc02>] do_irq+0x50/0x84
[    5.469730] [<ffffffff80003660>] ret_from_exception+0x0/0x64    // 广义上的异常处理入口
[    5.470575] [<ffffffff8083c4da>] default_idle_call+0x26/0x34ootfs+0x0/0x68 
```

##### setup_trap_vector
内核_start开始初始化的时候会设置异常向量寄存器  
下面代码并没有显式设置跳转模式，可能是因为`ENTRY(handle_exception)`定义至少4字节对齐  
所以函数地址低两位为0，就相当于配置为直接跳转模式  
```
arch/riscv/kernel/head.S
...
  175 .align 2
   176 setup_trap_vector:
   177         /* Set trap vector to exception handler */
   178         la a0, handle_exception
   179         csrw CSR_TVEC, a0    // 设置stvec寄存器，模式为直接跳转模式(handle_exception地址低两位为0)
   180
   181         /*
   182          * Set sup0 scratch register to 0, indicating to exception vector that
   183          * we are presently executing in kernel.
   184          */
   185         csrw CSR_SCRATCH, zero
   186         ret
.....
  317         call setup_trap_vector
   318         /* Restore C environment */
   319         la tp, init_task
   320         la sp, init_thread_union + THREAD_SIZE
   321
   322 #ifdef CONFIG_KASAN
   323         call kasan_early_init
   324 #endif
   325         /* Start the kernel */
   326         call soc_early_init
   327         tail start_kernel

```

##### set_handle_irq
```
start_kernel
  init_IRQ
  	irqchip_init  
  		of_irq_init
  			riscv_intc_init
                 		set_handle_irq(&riscv_intc_irq);   // handle_arch_irq == riscv_intc_irq

int __init set_handle_irq(void (*handle_irq)(struct pt_regs *))
{
	if (handle_arch_irq)
		return -EBUSY;

	handle_arch_irq = handle_irq;
	return 0;
}
```

##### generic_handle_arch_irq
generic_handle_arch_irq是中断响应总的入口，具体中断类型会在riscv_intc_irq中做区分
```
kernel/irq/handle.c

/**
 * generic_handle_arch_irq - root irq handler for architectures which do no
 *                           entry accounting themselves
 * @regs:	Register file coming from the low-level handling code
 */
asmlinkage void noinstr generic_handle_arch_irq(struct pt_regs *regs)
{
	struct pt_regs *old_regs;

	irq_enter();
	old_regs = set_irq_regs(regs);
	handle_arch_irq(regs);    // riscv_intc_irq
	set_irq_regs(old_regs);
	irq_exit();
}
```

##### riscv_intc_irq
IPI和其它中断分开处理 
```
static asmlinkage void riscv_intc_irq(struct pt_regs *regs)
{
	unsigned long cause = regs->cause & ~CAUSE_IRQ_FLAG;

	if (unlikely(cause >= BITS_PER_LONG))
		panic("unexpected interrupt cause");

	switch (cause) {
#ifdef CONFIG_SMP
	case RV_IRQ_SOFT:  // riscv架构IPI中断属于软件中断
		/*
		 * We only use software interrupts to pass IPIs, so if a
		 * non-SMP system gets one, then we don't know what to do.
		 */
		handle_IPI(regs);
		break;
#endif
	default:
		generic_handle_domain_irq(intc_domain, cause);
		break;
	}
}
```

##### handle_exception
```
/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (C) 2012 Regents of the University of California
 * Copyright (C) 2017 SiFive
 */

#include <linux/init.h>
#include <linux/linkage.h>

#include <asm/asm.h>
#include <asm/csr.h>
#include <asm/unistd.h>
#include <asm/thread_info.h>
#include <asm/asm-offsets.h>
#include <asm/errata_list.h>

#if !IS_ENABLED(CONFIG_PREEMPTION)
.set resume_kernel, restore_all
#endif

ENTRY(handle_exception)
	/*
	 * If coming from userspace, preserve the user thread pointer and load
	 * the kernel thread pointer.  If we came from the kernel, the scratch
	 * register will contain 0, and we should continue on the current TP.
	 */
	csrrw tp, CSR_SCRATCH, tp // 将CSR_SCRATCH 与 tp交换
	bnez tp, _save_context // tp == 0 异常打断的是内核态；tp != 0 打断的是用户态

_restore_kernel_tpsp:
	csrr tp, CSR_SCRATCH // 重新读sscratch的值到tp，即当前内核线程对应的struct task_struct地址
	REG_S sp, TASK_TI_KERNEL_SP(tp) // 保存sp寄存器的值到 thread_info.kernel_sp

#ifdef CONFIG_VMAP_STACK
	addi sp, sp, -(PT_SIZE_ON_STACK)
	srli sp, sp, THREAD_SHIFT
	andi sp, sp, 0x1
	bnez sp, handle_kernel_stack_overflow // 检测sp会不会溢出
	REG_L sp, TASK_TI_KERNEL_SP(tp)
#endif

_save_context:  // 保存异常上下文
	REG_S sp, TASK_TI_USER_SP(tp) // 保存tp寄存器的值到 thread_info.user_sp
	REG_L sp, TASK_TI_KERNEL_SP(tp) // 重新获取前面保存的sp的值
	addi sp, sp, -(PT_SIZE_ON_STACK) // 为异常上下文保留栈空间，保存各个寄存器的值
	REG_S x1,  PT_RA(sp)
	REG_S x3,  PT_GP(sp)
	REG_S x5,  PT_T0(sp)
	REG_S x6,  PT_T1(sp)
	REG_S x7,  PT_T2(sp)
	REG_S x8,  PT_S0(sp)
	REG_S x9,  PT_S1(sp)
	REG_S x10, PT_A0(sp)
	REG_S x11, PT_A1(sp)
	REG_S x12, PT_A2(sp)
	REG_S x13, PT_A3(sp)
	REG_S x14, PT_A4(sp)
	REG_S x15, PT_A5(sp)
	REG_S x16, PT_A6(sp)
	REG_S x17, PT_A7(sp)
	REG_S x18, PT_S2(sp)
	REG_S x19, PT_S3(sp)
	REG_S x20, PT_S4(sp)
	REG_S x21, PT_S5(sp)
	REG_S x22, PT_S6(sp)
	REG_S x23, PT_S7(sp)
	REG_S x24, PT_S8(sp)
	REG_S x25, PT_S9(sp)
	REG_S x26, PT_S10(sp)
	REG_S x27, PT_S11(sp)
	REG_S x28, PT_T3(sp)
	REG_S x29, PT_T4(sp)
	REG_S x30, PT_T5(sp)
	REG_S x31, PT_T6(sp)

	/*
	 * Disable user-mode memory access as it should only be set in the
	 * actual user copy routines.
	 *
	 * Disable the FPU to detect illegal usage of floating point in kernel
	 * space.
	 */
	li t0, SR_SUM | SR_FS // 当前场合内核态不允许访问用户态内存，并且禁用浮点

	REG_L s0, TASK_TI_USER_SP(tp)
	csrrc s1, CSR_STATUS, t0 // t0 设置到sstatus寄存器
	csrr s2, CSR_EPC
	csrr s3, CSR_TVAL
	csrr s4, CSR_CAUSE
	csrr s5, CSR_SCRATCH
	REG_S s0, PT_SP(sp)  // 解析具体异常时需要用到的几个寄存器也要保存到栈上
	REG_S s1, PT_STATUS(sp)
	REG_S s2, PT_EPC(sp)
	REG_S s3, PT_BADADDR(sp)
	REG_S s4, PT_CAUSE(sp)
	REG_S s5, PT_TP(sp)

	/*
	 * Set the scratch register to 0, so that if a recursive exception
	 * occurs, the exception vector knows it came from the kernel
	 */
	csrw CSR_SCRATCH, x0 // scrach寄存器清零，应对下一次异常

	/* Load the global pointer */
.option push
.option norelax
	la gp, __global_pointer$
.option pop

#ifdef CONFIG_TRACE_IRQFLAGS
	call __trace_hardirqs_off
#endif

#ifdef CONFIG_CONTEXT_TRACKING_USER
	/* If previous state is in user mode, call user_exit_callable(). */
	li   a0, SR_PP
	and a0, s1, a0
	bnez a0, skip_context_tracking
	call user_exit_callable
skip_context_tracking:
#endif

	/*
	 * MSB of cause differentiates between
	 * interrupts and exceptions
	 */
	bge s4, zero, 1f // 最高位为1表示负数，代表中断；否则代表异常，向前跳转到1f

	la ra, ret_from_exception   // 加载ret_from_exception地址到ra寄存器

	/* Handle interrupts */
	move a0, sp /* pt_regs */
	la a1, generic_handle_arch_irq   // C代码通用中断处理流程
	jr a1
1: // 异常处理流程
	/*
	 * Exceptions run with interrupts enabled or disabled depending on the
	 * state of SR_PIE in m/sstatus.
	 */
	andi t0, s1, SR_PIE // sstatus.SPIE
	beqz t0, 1f     // 为0表示本次异常之前的中断使能状态为关中断，跳转到1f
	/* kprobes, entered via ebreak, must have interrupts disabled. */
	li t0, EXC_BREAKPOINT
	beq s4, t0, 1f  // 如果s4 == EXC_BREAKPOINT，代表断点异常
#ifdef CONFIG_TRACE_IRQFLAGS
	call __trace_hardirqs_on
#endif
	csrs CSR_STATUS, SR_IE // 使能中断

1:
	la ra, ret_from_exception // 加载ret_from_exception地址到ra寄存器
	/* Handle syscalls */
	li t0, EXC_SYSCALL
	beq s4, t0, handle_syscall // 系统调用异常

	/* Handle other exceptions */  // 处理其它异常
	slli t0, s4, RISCV_LGPTR
	la t1, excp_vect_table   // 循环遍历异常向量表
	la t2, excp_vect_table_end
	move a0, sp /* pt_regs */
	add t0, t1, t0
	/* Check if exception code lies within bounds */
	bgeu t0, t2, 1f
	REG_L t0, 0(t0)
	jr t0
1:
	tail do_trap_unknown   //处理未知异常

handle_syscall:
#ifdef CONFIG_RISCV_M_MODE
	/*
	 * When running is M-Mode (no MMU config), MPIE does not get set.
	 * As a result, we need to force enable interrupts here because
	 * handle_exception did not do set SR_IE as it always sees SR_PIE
	 * being cleared.
	 */
	csrs CSR_STATUS, SR_IE
#endif
#if defined(CONFIG_TRACE_IRQFLAGS) || defined(CONFIG_CONTEXT_TRACKING_USER)
	/* Recover a0 - a7 for system calls */
	REG_L a0, PT_A0(sp)
	REG_L a1, PT_A1(sp)
	REG_L a2, PT_A2(sp)
	REG_L a3, PT_A3(sp)
	REG_L a4, PT_A4(sp)
	REG_L a5, PT_A5(sp)
	REG_L a6, PT_A6(sp)
	REG_L a7, PT_A7(sp)
#endif
	 /* save the initial A0 value (needed in signal handlers) */
	REG_S a0, PT_ORIG_A0(sp)
	/*
	 * Advance SEPC to avoid executing the original
	 * scall instruction on sret
	 */
	addi s2, s2, 0x4
	REG_S s2, PT_EPC(sp)
	/* Trace syscalls, but only if requested by the user. */
	REG_L t0, TASK_TI_FLAGS(tp)
	andi t0, t0, _TIF_SYSCALL_WORK
	bnez t0, handle_syscall_trace_enter
check_syscall_nr:
	/* Check to make sure we don't jump to a bogus syscall number. */
	li t0, __NR_syscalls
	la s0, sys_ni_syscall
	/*
	 * Syscall number held in a7.
	 * If syscall number is above allowed value, redirect to ni_syscall.
	 */
	bgeu a7, t0, 3f
#ifdef CONFIG_COMPAT
	REG_L s0, PT_STATUS(sp)
	srli s0, s0, SR_UXL_SHIFT
	andi s0, s0, (SR_UXL >> SR_UXL_SHIFT)
	li t0, (SR_UXL_32 >> SR_UXL_SHIFT)
	sub t0, s0, t0
	bnez t0, 1f

	/* Call compat_syscall */
	la s0, compat_sys_call_table
	j 2f
1:
#endif
	/* Call syscall */
	la s0, sys_call_table
2:
	slli t0, a7, RISCV_LGPTR
	add s0, s0, t0
	REG_L s0, 0(s0)
3:
	jalr s0

ret_from_syscall:
	/* Set user a0 to kernel a0 */
	REG_S a0, PT_A0(sp)
	/*
	 * We didn't execute the actual syscall.
	 * Seccomp already set return value for the current task pt_regs.
	 * (If it was configured with SECCOMP_RET_ERRNO/TRACE)
	 */
ret_from_syscall_rejected:
#ifdef CONFIG_DEBUG_RSEQ
	move a0, sp
	call rseq_syscall
#endif
	/* Trace syscalls, but only if requested by the user. */
	REG_L t0, TASK_TI_FLAGS(tp)
	andi t0, t0, _TIF_SYSCALL_WORK
	bnez t0, handle_syscall_trace_exit

SYM_CODE_START_NOALIGN(ret_from_exception)   // 异常处理完毕返回
	REG_L s0, PT_STATUS(sp)    // 加载保存在栈上的sstatus值到寄存器s0
	csrc CSR_STATUS, SR_IE   // 关中断
#ifdef CONFIG_TRACE_IRQFLAGS
	call __trace_hardirqs_off
#endif
#ifdef CONFIG_RISCV_M_MODE
	/* the MPP value is too large to be used as an immediate arg for addi */
	li t0, SR_MPP
	and s0, s0, t0
#else
	andi s0, s0, SR_SPP   // 检测sstatus.SPP比特位，为1表示异常发生前的特权模式为S模式，为0表示U模式
#endif
	bnez s0, resume_kernel // 如果不为0，异常发生前的特权模式为S模式，跳转到resume_kernel
SYM_CODE_END(ret_from_exception)

	// 异常前的特权模式为U模式
	/* Interrupts must be disabled here so flags are checked atomically */
	REG_L s0, TASK_TI_FLAGS(tp) /* current_thread_info->flags */
	andi s1, s0, _TIF_WORK_MASK   // 返回到用户态之前检测是否还有其它任务需要处理(调度、信号等)
	bnez s1, resume_userspace_slow // 如果s1不为0，进入slow流程，处理其它任务

resume_userspace:   			// 返回到用户态
#ifdef CONFIG_CONTEXT_TRACKING_USER
	call user_enter_callable
#endif

	/* Save unwound kernel stack pointer in thread_info */
	addi s0, sp, PT_SIZE_ON_STACK  // 退栈
	REG_S s0, TASK_TI_KERNEL_SP(tp)  //保存进程内核栈地址到thread_info.kernel_sp

	/*
	 * Save TP into the scratch register , so we can find the kernel data
	 * structures again.
	 */
	csrw CSR_SCRATCH, tp  // 交换tp和sscratch，把task_struct的地址还放进tp

restore_all:   // 异常处理结束前恢复被打断的寄存器上下文
#ifdef CONFIG_TRACE_IRQFLAGS
	REG_L s1, PT_STATUS(sp)
	andi t0, s1, SR_PIE
	beqz t0, 1f
	call __trace_hardirqs_on
	j 2f
1:
	call __trace_hardirqs_off
2:
#endif
	REG_L a0, PT_STATUS(sp)
	/*
	 * The current load reservation is effectively part of the processor's
	 * state, in the sense that load reservations cannot be shared between
	 * different hart contexts.  We can't actually save and restore a load
	 * reservation, so instead here we clear any existing reservation --
	 * it's always legal for implementations to clear load reservations at
	 * any point (as long as the forward progress guarantee is kept, but
	 * we'll ignore that here).
	 *
	 * Dangling load reservations can be the result of taking a trap in the
	 * middle of an LR/SC sequence, but can also be the result of a taken
	 * forward branch around an SC -- which is how we implement CAS.  As a
	 * result we need to clear reservations between the last CAS and the
	 * jump back to the new context.  While it is unlikely the store
	 * completes, implementations are allowed to expand reservations to be
	 * arbitrarily large.
	 */
	REG_L  a2, PT_EPC(sp)
	REG_SC x0, a2, PT_EPC(sp)  // sc.d    zero,a2,(sp) 清零a2和sp.epc

	csrw CSR_STATUS, a0    // 写回sstatus
	csrw CSR_EPC, a2     // 写回sepc

	REG_L x1,  PT_RA(sp)
	REG_L x3,  PT_GP(sp)
	REG_L x4,  PT_TP(sp)
	REG_L x5,  PT_T0(sp)
	REG_L x6,  PT_T1(sp)
	REG_L x7,  PT_T2(sp)
	REG_L x8,  PT_S0(sp)
	REG_L x9,  PT_S1(sp)
	REG_L x10, PT_A0(sp)
	REG_L x11, PT_A1(sp)
	REG_L x12, PT_A2(sp)
	REG_L x13, PT_A3(sp)
	REG_L x14, PT_A4(sp)
	REG_L x15, PT_A5(sp)
	REG_L x16, PT_A6(sp)
	REG_L x17, PT_A7(sp)
	REG_L x18, PT_S2(sp)
	REG_L x19, PT_S3(sp)
	REG_L x20, PT_S4(sp)
	REG_L x21, PT_S5(sp)
	REG_L x22, PT_S6(sp)
	REG_L x23, PT_S7(sp)
	REG_L x24, PT_S8(sp)
	REG_L x25, PT_S9(sp)
	REG_L x26, PT_S10(sp)
	REG_L x27, PT_S11(sp)
	REG_L x28, PT_T3(sp)
	REG_L x29, PT_T4(sp)
	REG_L x30, PT_T5(sp)
	REG_L x31, PT_T6(sp)

	REG_L x2,  PT_SP(sp)

#ifdef CONFIG_RISCV_M_MODE
	mret
#else
	sret   // 异常返回
#endif

#if IS_ENABLED(CONFIG_PREEMPTION)
resume_kernel:
	REG_L s0, TASK_TI_PREEMPT_COUNT(tp)
	bnez s0, restore_all
	REG_L s0, TASK_TI_FLAGS(tp)
	andi s0, s0, _TIF_NEED_RESCHED
	beqz s0, restore_all
	call preempt_schedule_irq
	j restore_all
#endif

resume_userspace_slow:
	/* Enter slow path for supplementary processing */
	move a0, sp /* pt_regs */
	move a1, s0 /* current_thread_info->flags */
	call do_work_pending
	j resume_userspace

/* Slow paths for ptrace. */
handle_syscall_trace_enter:
	move a0, sp
	call do_syscall_trace_enter
	move t0, a0
	REG_L a0, PT_A0(sp)
	REG_L a1, PT_A1(sp)
	REG_L a2, PT_A2(sp)
	REG_L a3, PT_A3(sp)
	REG_L a4, PT_A4(sp)
	REG_L a5, PT_A5(sp)
	REG_L a6, PT_A6(sp)
	REG_L a7, PT_A7(sp)
	bnez t0, ret_from_syscall_rejected
	j check_syscall_nr
handle_syscall_trace_exit:
	move a0, sp
	call do_syscall_trace_exit
	j ret_from_exception

#ifdef CONFIG_VMAP_STACK
handle_kernel_stack_overflow:
	/*
	 * Takes the psuedo-spinlock for the shadow stack, in case multiple
	 * harts are concurrently overflowing their kernel stacks.  We could
	 * store any value here, but since we're overflowing the kernel stack
	 * already we only have SP to use as a scratch register.  So we just
	 * swap in the address of the spinlock, as that's definately non-zero.
	 *
	 * Pairs with a store_release in handle_bad_stack().
	 */
1:	la sp, spin_shadow_stack
	REG_AMOSWAP_AQ sp, sp, (sp)
	bnez sp, 1b

	la sp, shadow_stack
	addi sp, sp, SHADOW_OVERFLOW_STACK_SIZE

	//save caller register to shadow stack
	addi sp, sp, -(PT_SIZE_ON_STACK)
	REG_S x1,  PT_RA(sp)
	REG_S x5,  PT_T0(sp)
	REG_S x6,  PT_T1(sp)
	REG_S x7,  PT_T2(sp)
	REG_S x10, PT_A0(sp)
	REG_S x11, PT_A1(sp)
	REG_S x12, PT_A2(sp)
	REG_S x13, PT_A3(sp)
	REG_S x14, PT_A4(sp)
	REG_S x15, PT_A5(sp)
	REG_S x16, PT_A6(sp)
	REG_S x17, PT_A7(sp)
	REG_S x28, PT_T3(sp)
	REG_S x29, PT_T4(sp)
	REG_S x30, PT_T5(sp)
	REG_S x31, PT_T6(sp)

	la ra, restore_caller_reg
	tail get_overflow_stack

restore_caller_reg:
	//save per-cpu overflow stack
	REG_S a0, -8(sp)
	//restore caller register from shadow_stack
	REG_L x1,  PT_RA(sp)
	REG_L x5,  PT_T0(sp)
	REG_L x6,  PT_T1(sp)
	REG_L x7,  PT_T2(sp)
	REG_L x10, PT_A0(sp)
	REG_L x11, PT_A1(sp)
	REG_L x12, PT_A2(sp)
	REG_L x13, PT_A3(sp)
	REG_L x14, PT_A4(sp)
	REG_L x15, PT_A5(sp)
	REG_L x16, PT_A6(sp)
	REG_L x17, PT_A7(sp)
	REG_L x28, PT_T3(sp)
	REG_L x29, PT_T4(sp)
	REG_L x30, PT_T5(sp)
	REG_L x31, PT_T6(sp)

	//load per-cpu overflow stack
	REG_L sp, -8(sp)
	addi sp, sp, -(PT_SIZE_ON_STACK)

	//save context to overflow stack
	REG_S x1,  PT_RA(sp)
	REG_S x3,  PT_GP(sp)
	REG_S x5,  PT_T0(sp)
	REG_S x6,  PT_T1(sp)
	REG_S x7,  PT_T2(sp)
	REG_S x8,  PT_S0(sp)
	REG_S x9,  PT_S1(sp)
	REG_S x10, PT_A0(sp)
	REG_S x11, PT_A1(sp)
	REG_S x12, PT_A2(sp)
	REG_S x13, PT_A3(sp)
	REG_S x14, PT_A4(sp)
	REG_S x15, PT_A5(sp)
	REG_S x16, PT_A6(sp)
	REG_S x17, PT_A7(sp)
	REG_S x18, PT_S2(sp)
	REG_S x19, PT_S3(sp)
	REG_S x20, PT_S4(sp)
	REG_S x21, PT_S5(sp)
	REG_S x22, PT_S6(sp)
	REG_S x23, PT_S7(sp)
	REG_S x24, PT_S8(sp)
	REG_S x25, PT_S9(sp)
	REG_S x26, PT_S10(sp)
	REG_S x27, PT_S11(sp)
	REG_S x28, PT_T3(sp)
	REG_S x29, PT_T4(sp)
	REG_S x30, PT_T5(sp)
	REG_S x31, PT_T6(sp)

	REG_L s0, TASK_TI_KERNEL_SP(tp)
	csrr s1, CSR_STATUS
	csrr s2, CSR_EPC
	csrr s3, CSR_TVAL
	csrr s4, CSR_CAUSE
	csrr s5, CSR_SCRATCH
	REG_S s0, PT_SP(sp)
	REG_S s1, PT_STATUS(sp)
	REG_S s2, PT_EPC(sp)
	REG_S s3, PT_BADADDR(sp)
	REG_S s4, PT_CAUSE(sp)
	REG_S s5, PT_TP(sp)
	move a0, sp
	tail handle_bad_stack
#endif

END(handle_exception)

ENTRY(ret_from_fork)
	la ra, ret_from_exception
	tail schedule_tail
ENDPROC(ret_from_fork)

ENTRY(ret_from_kernel_thread)
	call schedule_tail
	/* Call fn(arg) */
	la ra, ret_from_exception
	move a0, s1
	jr s0
ENDPROC(ret_from_kernel_thread)


/*
 * Integer register context switch
 * The callee-saved registers must be saved and restored.
 *
 *   a0: previous task_struct (must be preserved across the switch)
 *   a1: next task_struct
 *
 * The value of a0 and a1 must be preserved by this function, as that's how
 * arguments are passed to schedule_tail.
 */
ENTRY(__switch_to)
	/* Save context into prev->thread */
	li    a4,  TASK_THREAD_RA
	add   a3, a0, a4
	add   a4, a1, a4
	REG_S ra,  TASK_THREAD_RA_RA(a3)
	REG_S sp,  TASK_THREAD_SP_RA(a3)
	REG_S s0,  TASK_THREAD_S0_RA(a3)
	REG_S s1,  TASK_THREAD_S1_RA(a3)
	REG_S s2,  TASK_THREAD_S2_RA(a3)
	REG_S s3,  TASK_THREAD_S3_RA(a3)
	REG_S s4,  TASK_THREAD_S4_RA(a3)
	REG_S s5,  TASK_THREAD_S5_RA(a3)
	REG_S s6,  TASK_THREAD_S6_RA(a3)
	REG_S s7,  TASK_THREAD_S7_RA(a3)
	REG_S s8,  TASK_THREAD_S8_RA(a3)
	REG_S s9,  TASK_THREAD_S9_RA(a3)
	REG_S s10, TASK_THREAD_S10_RA(a3)
	REG_S s11, TASK_THREAD_S11_RA(a3)
	/* Restore context from next->thread */
	REG_L ra,  TASK_THREAD_RA_RA(a4)
	REG_L sp,  TASK_THREAD_SP_RA(a4)
	REG_L s0,  TASK_THREAD_S0_RA(a4)
	REG_L s1,  TASK_THREAD_S1_RA(a4)
	REG_L s2,  TASK_THREAD_S2_RA(a4)
	REG_L s3,  TASK_THREAD_S3_RA(a4)
	REG_L s4,  TASK_THREAD_S4_RA(a4)
	REG_L s5,  TASK_THREAD_S5_RA(a4)
	REG_L s6,  TASK_THREAD_S6_RA(a4)
	REG_L s7,  TASK_THREAD_S7_RA(a4)
	REG_L s8,  TASK_THREAD_S8_RA(a4)
	REG_L s9,  TASK_THREAD_S9_RA(a4)
	REG_L s10, TASK_THREAD_S10_RA(a4)
	REG_L s11, TASK_THREAD_S11_RA(a4)
	/* The offset of thread_info in task_struct is zero. */
	move tp, a1
	ret
ENDPROC(__switch_to)

#ifndef CONFIG_MMU
#define do_page_fault do_trap_unknown
#endif

	.section ".rodata"
	.align LGREG
	/* Exception vector table */
ENTRY(excp_vect_table)
	RISCV_PTR do_trap_insn_misaligned
	ALT_INSN_FAULT(RISCV_PTR do_trap_insn_fault)
	RISCV_PTR do_trap_insn_illegal
	RISCV_PTR do_trap_break
	RISCV_PTR do_trap_load_misaligned
	RISCV_PTR do_trap_load_fault
	RISCV_PTR do_trap_store_misaligned
	RISCV_PTR do_trap_store_fault
	RISCV_PTR do_trap_ecall_u /* system call, gets intercepted */
	RISCV_PTR do_trap_ecall_s
	RISCV_PTR do_trap_unknown
	RISCV_PTR do_trap_ecall_m
	/* instruciton page fault */
	ALT_PAGE_FAULT(RISCV_PTR do_page_fault)
	RISCV_PTR do_page_fault   /* load page fault */
	RISCV_PTR do_trap_unknown
	RISCV_PTR do_page_fault   /* store page fault */
excp_vect_table_end:
END(excp_vect_table)

#ifndef CONFIG_MMU
ENTRY(__user_rt_sigreturn)
	li a7, __NR_rt_sigreturn
	scall
END(__user_rt_sigreturn)
#endif
```

### 参考链接
[linux-6.2](https://elixir.bootlin.com/linux/v6.2/source)  
[RISC-V Manual Volume II Privileged Architecture Version 1.10](https://riscv.org/wp-content/uploads/2017/05/riscv-privileged-v1.10.pdf)    
