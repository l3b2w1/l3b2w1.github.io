---
layout:     post
title:      opensbi 启动流程
subtitle:   fw_base.S 和 sbi_init代码分析
date:       2023-07-03
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - riscv
    - opensbi
    - qemu
---

**主要关注 fw_base.S 和 sbi_init**
```
firmware/fw_base.S
	...   // 为每个hart 都准备好了各自的struct sbi_scatch
	call    sbi_init
```

## fw_jump.elf编译命令
```
riscv64-unknown-linux-gnu-gcc -g -Wall -nostdlib -fno-omit-frame-pointer -fno-optimize-sibling-calls \
  -mstrict-align -mno-save-restore -mabi=lp64 -march=rv64imafdc_zicsr_zifencei -mcmodel=medany  \
  -I/home/linux/riscv/opensbi-master-orig/platform/generic/include -I/home/linux/riscv/opensbi-master-orig/include \
	-include /home/linux/riscv/opensbi-master -orig/build/platform/generic/kconfig/autoconf.h \
  -I/home/linux/riscv/opensbi-master-orig/lib/utils/libfdt/ \
	-DFW_PIC -DFW_TEXT_START=0x80000000 -DFW_JUMP_ADDR=0x80200000 -DFW_JUMP_FDT_ADDR=0x82200000  \
	-DFW_PAYLOAD_PATH=\"/home/linux/riscv/opensbi-master-orig/build/platform/generic/firmware/payloads/test.bin\" \
  -DFW_PAYLOAD_OFFSET=0x200000 -DFW_PAYLOAD_FDT_ADDR=0x82200000  \
  -fpic -I/home/linux/riscv/opensbi-master-orig /firmware -D__OBJNAME__=fw_jump \
	-c /home/linux/riscv/opensbi-master-orig/firmware/fw_ jump.S \
  -o /home/linux/riscv/opensbi-master-orig/build/platform/generic/firmware/fw_jump.o
```

`-DFW_PIC -DFW_TEXT_START=0x80000000`  fw_jump.bin 链接入口地址  
`-DFW_JUMP_ADDR=0x80200000` opensbi初始化完成后，跳转到下一阶段开始执行的地址，比如kernel image入口地址  
`-DFW_JUMP_FDT_ADDR=0x82200000`  fdt首地址  


## fw_base.S主要任务

只关注加载地址和链接地址相同的情况下  
	1. 随机选中某个hart作为boot hart，负责执行后面2-7步骤；其它hart跳转到`_wait_for_boot_har`t等待  
	2. 计算加载地址和链接地址的偏差，存入`_runtime_offset`变量  
	3. 遍历`.rel.dyn`每一个表项进行重定位操作，结束后把`BOOT_STATUS_RELOCATE_DONE`标记写入`_boot_status`变量        
	4. 清零bss区域  
	5. 解析dtb初始化`struct sbi_platform`，填充成员变量  
	6. 为所有harts分配`struct sbi_scratch`空间，从hart 0开始初始化每一个cpu对应的`struct sbi_scratch`，填充各个字段  
	7. 执行fdt重定位，把BOOT_STATUS_BOOT_HART_DONE标记写入_boot_status，通过fence内存屏障通知其它cpu，接着跳转到`_start_warm`  
  	8. 所有其它等待的cpu观察到`_boot_status`已经更新为`BOOT_STATUS_BOOT_HART_DONE后`，就跳转到`_start_warm`   

**_start_warm执行流程，所有hart都会执行到这里并且调用C函数sbi_init**  
	1. 清零通用寄存器和`CSR_MSCRATCH`，冲刷指令缓存  
	2. 清零`CSR_MIE`，禁止所有中断  
	3. 清零`CSR_MIP`的`MIP_SSIP`和`MIP_STIP`比特位  
	4. 找到当前cpu对应`sbi_scratch`地址后写入`CSR_MSCRATCH`  
	5. 设置栈帧位置sp  
	6. `_trap_handler`写入`CSR_MTVEC`  
  	7. 获取`CSR_MSCRATCH`，保存到a0，最为入参，调用`sbi_init`C函数

**只有一个cpu成为coldboot hart，其它为warmboot harts  
只有支持scratch->next_mode指定的特权模式的hart才可以成为coldboot hart  
因为需要该coldboot hart直接跳转到下一启动阶段，比如linux内核镜像**

## qemu启动riscv内核镜像
启动命令
```
qemu-system-riscv64 -M virt -m 4096M -smp 16 -cpu rv64 \
        -bios ./build/platform/generic/firmware/fw_jump.elf \
        -kernel $KERNEL_DIR/arch/riscv/boot/Image \
        -append "nokaslr root=/dev/vda rw console=ttyS0,115200 earlycon=uart8250 kgdboc=ttyS0,115200 loglevel=10" \
        -drive file=riscv-rootfs.ext2,format=raw,id=hd0 -device virtio-blk-device,drive=hd0 \
        -nographic
```

##### struct sbi_platform
```
qemu-riscv.dts
   1 /dts-v1/;
   2
   3 / {
   4         #address-cells = <0x02>;
   5         #size-cells = <0x02>;
   6         compatible = "riscv-virtio";

   7         model = "riscv-virtio,qemu";
```
```
(gdb) x/28wx 0x800201e0   // struct sbi_platform
0x800201e0 <platform>:  0x00010002      0x00000001      0x63736972      0x69762d76      
0x800201f0 <platform+16>:       0x6f697472      0x6d65712c      0x00000075      0x00000000    // riscv-virtio,qemu
0x80020200 <platform+32>:       0x00000000      0x00000000      0x00000000      0x00000000
0x80020210 <platform+48>:       0x00000000      0x00000000      0x00000000      0x00000000
0x80020220 <platform+64>:       0x00000000      0x00000000      0x00000002      0x00000000   //   0x00000002       Supported features
0x80020230 <platform+80>:       0x00000010      0x00002000      0x80020250      0x00000000   //   0x000000010 16个cpu 对应qemu -smp 16;    0x80020250    platform_ops_addr  
0x80020240 <platform+96>:       0x00000000      0x00000000      0x8002eab8      0x00000000   //   hart_index2id(generic_hart_index2id)
0x80020250 <platform_ops>:      0x80003f18      0x00000000      0x80004190      0x00000000
```

```
struct sbi_platform {
	/**
	 * OpenSBI version this sbi_platform is based on.
	 * It's a 32-bit value where upper 16-bits are major number
	 * and lower 16-bits are minor number
	 */
	u32 opensbi_version;    //  v1.2
	/**
	 * OpenSBI platform version released by vendor.
	 * It's a 32-bit value where upper 16-bits are major number
	 * and lower 16-bits are minor number
	 */
	u32 platform_version;
	/** Name of the platform */
	char name[64];                     // model = "riscv-virtio,qemu"
	/** Supported features */
	u64 features;              // 支持特性
	/** Total number of HARTs */
	u32 hart_count;                // cpu个数
	/** Per-HART stack size for exception/interrupt handling */
	u32 hart_stack_size;       //  0x00002000  栈大小8k
	/** Pointer to sbi platform operations */
	unsigned long platform_ops_addr;
	/** Pointer to system firmware specific context */
	unsigned long firmware_context;
	/**
	 * HART index to HART id table
	 *
	 * For used HART index <abc>:
	 *     hart_index2id[<abc>] = some HART id
	 * For unused HART index <abc>:
	 *     hart_index2id[<abc>] = -1U
	 *
	 * If hart_index2id == NULL then we assume identity mapping
	 *     hart_index2id[<abc>] = <abc>
	 *
	 * We have only two restrictions:
	 * 1. HART index < sbi_platform hart_count
	 * 2. HART id < SBI_HARTMASK_MAX_BITS
	 */
	const u32 *hart_index2id;
};
```

**hart_index2id**  
generic_hart_index2id是包含128个元素的数组，前16个元素对应16个cpu  
```
#define SBI_HARTMASK_MAX_BITS           128
static u32 generic_hart_index2id[SBI_HARTMASK_MAX_BITS] = { 0 };
```

```
(gdb) x/16wx 0x8002eab8
0x8002eab8 <generic_hart_index2id>:     0x00000000      0x00000001      0x00000002      0x00000003
0x8002eac8 <generic_hart_index2id+16>:  0x00000004      0x00000005      0x00000006      0x00000007
0x8002ead8 <generic_hart_index2id+32>:  0x00000008      0x00000009      0x0000000a      0x0000000b
0x8002eae8 <generic_hart_index2id+48>:  0x0000000c      0x0000000d      0x0000000e      0x0000000f
0x8002eaf8 <generic_hart_index2id+64>:  0x00000000      0x00000000      0x00000000      0x00000000

```

##### struct sbi_scratch
qemu gdb断点sbi_init，入参a0为struct sbi_scratch *scratch
```
(gdb) x/8gx $a0
0x80039000:     0x0000000080000000      0x000000000003a000  // fw_start ;    fw_size
0x80039010:     0x0000000000020000      0x0000000082200000   //  fw_rw_offset;    next_arg1(fdt地址)
0x80039020:     0x0000000080200000      0x0000000000000001   //   next_addr  OS镜像加载地址为0x80200000 ；下一级权限模式为1 Supervisor特权级
0x80039030:     0x0000000080000354      0x00000000800201e0   // warmboot_addr   热启动入口地址；platform_addr 即sbi_platform地址
0x80039040:     0x00000000800003d8      0x00000000800004a6  // hartid_to_scratch      ;   trap_exit

0x80039050:     0x0000000000000000      0x0000000000000000  //  tmp0    ;   options
```

```
/** Representation of per-HART scratch space */
struct sbi_scratch {
	/** Start (or base) address of firmware linked to OpenSBI library */
	unsigned long fw_start;	// 0x80000000    fw_jump text起始地址

	/** Size (in bytes) of firmware linked to OpenSBI library */
	unsigned long fw_size;	// 0x0003a000

	/** Offset (in bytes) of the R/W section */
	unsigned long fw_rw_offset;		// 	0x00020000

	/** Arg1 (or 'a1' register) of next booting stage for this HART */
	unsigned long next_arg1;		// 	0x82200000   fdt地址，是要传递给下一启动阶段的参数

	/** Address of next booting stage for this HART */
	unsigned long next_addr;		// 0x80200000     内核镜像的入口_start

	/** Privilege mode of next booting stage for this HART */
	unsigned long next_mode;		//	0x00000001 代表 Supervisor mode 特权模式

	/** Warm boot entry point address for this HART */
	unsigned long warmboot_addr;	//	0x80000354

	/** Address of sbi_platform */
	unsigned long platform_addr;	// 	0x800201e0

	/** Address of HART ID to sbi_scratch conversion function */
	unsigned long hartid_to_scratch;		// 0x800003d8   firmware/fw_base.S 540行  _hartid_to_scratch

	/** Address of trap exit function */
	unsigned long trap_exit;		// 0x800004a6

	/** Temporary storage */
	unsigned long tmp0;		// 0x0

	/** Options for OpenSBI library */
	unsigned long options;	// 0x0
};
```

## fw_base.S汇编代码走读
已经删除掉无关流程，只关注_load_addr和_link_addr相同的情况
```
/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2019 Western Digital Corporation or its affiliates.
 *
 * Authors:
 *   Anup Patel <anup.patel@wdc.com>
 */

#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/riscv_elf.h>
#include <sbi/sbi_platform.h>
#include <sbi/sbi_scratch.h>
#include <sbi/sbi_trap.h>

#define BOOT_STATUS_RELOCATE_DONE	1
#define BOOT_STATUS_BOOT_HART_DONE	2

.macro	MOV_3R __d0, __s0, __d1, __s1, __d2, __s2
	add	\__d0, \__s0, zero
	add	\__d1, \__s1, zero
	add	\__d2, \__s2, zero
.endm

.macro	MOV_5R __d0, __s0, __d1, __s1, __d2, __s2, __d3, __s3, __d4, __s4
	add	\__d0, \__s0, zero
	add	\__d1, \__s1, zero
	add	\__d2, \__s2, zero
	add	\__d3, \__s3, zero
	add	\__d4, \__s4, zero
.endm

/*
 * If __start_reg <= __check_reg and __check_reg < __end_reg then
 *   jump to __pass
 */
.macro BRANGE __start_reg, __end_reg, __check_reg, __jump_lable
	blt	\__check_reg, \__start_reg, 999f
	bge	\__check_reg, \__end_reg, 999f
	j	\__jump_lable
999:
.endm

	.section .entry, "ax", %progbits
	.align 3
	.globl _start
	.globl _start_warm
_start:
	/* Find preferred boot HART id */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_boot_hart
	add	a6, a0, zero
	MOV_3R	a0, s0, a1, s1, a2, s2
	li	a7, -1
	beq	a6, a7, _try_lottery
	/* Jump to relocation wait loop if we are not boot hart */
	bne	a0, a6, _wait_relocate_copy_done
_try_lottery:
	/* Jump to relocation wait loop if we don't get relocation lottery */
	lla	a6, _relocate_lottery
	li	a7, 1
	amoadd.w a6, a7, (a6)  // amo原子指令保证同一时刻只有一个cpu可以成功写入1, 那么该cpu的a6为0，而其他cpu从a6中读到的数值都大于0
	bnez	a6, _wait_relocate_copy_done // a6不为0的cpu等待boot hart重定位和拷贝结束

	/* Save load address */
	lla	t0, _load_start // _load_start 变量所在物理地址加载到t0
	lla	t1, _fw_start  // _fw_start所在物理地址(即firmware实际加载地址,一般为0x80000000)加载到t1
	REG_S	t1, 0(t0)     // 保存load addr到_load_start

	//  qemu跟踪显示2f标签处每一个重定位表项t3和t5的值都是3,表示相对重定位
	/* 加载地址和链接地址相同 */
	/* relocate the global table content */
	lla	t0, _link_start  // _link_start变量所在物理地址加载到t0
	REG_L	t0, 0(t0)    // _link_start处的值加载到t0(链接地址即FW_TEXT_START)
	/* t1 shall has the address of _fw_start */
	sub	t2, t1, t0  // t2即为加载地址和链接地址之间的偏移量(二者相同，所以偏移为0)
	lla	t3, _runtime_offset
	REG_S	t2, (t3)   // 把t2中的运行时偏移量存储到_runtime_offset变量所在内存位置
	lla	t0, __rel_dyn_start  //把__rel_dyn_start变量地址加载到t0
	lla	t1, __rel_dyn_end   //把__rel_dyn_end变量地址加载到t1
	beq	t0, t1, _relocate_done // 如果t0==t1，即重定位结束，跳转到_relocate_done
	j	5f
2:
	REG_L	t5, -(REGBYTES*2)(t0)	/* t5 <-- relocation info:type */
	li	t3, R_RISCV_RELATIVE	/* reloc type R_RISCV_RELATIVE */
	bne	t5, t3, 3f             // 3f处理非相对重定位
	REG_L	t3, -(REGBYTES*3)(t0)   // 处理相对重定位, 加载表项中存储的需要重定位的具体位置
	REG_L	t5, -(REGBYTES)(t0)	/* t5 <-- addend */ // 加算子
	add	t5, t5, t2  		// 加上t2中的运行时偏移
	add	t3, t3, t2 		// 加上t2中的运行时偏移
	REG_S	t5, 0(t3)		/* store runtime address to the GOT entry */
	j	5f

3:
	lla	t4, __dyn_sym_start

4:
	REG_L	t5, -(REGBYTES*2)(t0)	/* t5 <-- relocation info:type */
	srli	t6, t5, SYM_INDEX	/* t6 <--- sym table index */
	andi	t5, t5, 0xFF		/* t5 <--- relocation type */
	li	t3, RELOC_TYPE
	bne	t5, t3, 5f

	/* address R_RISCV_64 or R_RISCV_32 cases*/
	REG_L	t3, -(REGBYTES*3)(t0)
	li	t5, SYM_SIZE
	mul	t6, t6, t5
	add	s5, t4, t6
	REG_L	t6, -(REGBYTES)(t0)	/* t0 <-- addend */
	REG_L	t5, REGBYTES(s5)
	add	t5, t5, t6
	add	t5, t5, t2		/* t5 <-- location to fix up in RAM */
	add	t3, t3, t2		/* t3 <-- location to fix up in RAM */
	REG_S	t5, 0(t3)		/* store runtime address to the variable */

5:
	addi	t0, t0, (REGBYTES*3) //循环步长为24字节，即每个重定位表项占24字节
	ble	t0, t1, 2b
	j	_relocate_done
_wait_relocate_copy_done:
	j	_wait_for_boot_hart

_relocate_done:

	/*
	 * Mark relocate copy done
	 * Use _boot_status copy relative to the load address
	 */
	lla	t0, _boot_status  // 加载_boot_status变量地址到t0

	li	t1, BOOT_STATUS_RELOCATE_DONE // 加载立即数标记到t1
	REG_S	t1, 0(t0)   // 标记写入_boot_status
	fence	rw, rw    // 内存屏障指令, 控制内存访问的顺序和可见性,执行结束标记对其它cpu可见

	/* At this point we are running from link address */

	/* Reset all registers for boot HART */ // 重置boot hart通用寄存器为0
	li	ra, 0
	call	_reset_regs

	/* Zero-out BSS */  // bss section清零
	lla	s4, _bss_start
	lla	s5, _bss_end
_bss_zero:
	REG_S	zero, (s4)
	add	s4, s4, __SIZEOF_POINTER__
	blt	s4, s5, _bss_zero

	/* Setup temporary trap handler */ // trap handler 写入CSR_MTVEC
	lla	s4, _start_hang
	csrw	CSR_MTVEC, s4

	/* Setup temporary stack */  // 设置临时堆栈,为后面调用C代码fw_platform_init做准备
	lla	s4, _fw_end
	li	s5, (SBI_SCRATCH_SIZE * 2)
	add	sp, s4, s5

	/* Allow main firmware to save info */
	MOV_5R	s0, a0, s1, a1, s2, a2, s3, a3, s4, a4
	call	fw_save_info
	MOV_5R	a0, s0, a1, s1, a2, s2, a3, s3, a4, s4

	/*
	 * Initialize platform
	 * Note: The a0 to a4 registers passed to the
	 * firmware are parameters to this function.
	 */
	MOV_5R	s0, a0, s1, a1, s2, a2, s3, a3, s4, a4
	call	fw_platform_init   // 通过解析dtb初始化struct sbi_platform
	add	t0, a0, zero
	MOV_5R	a0, s0, a1, s1, a2, s2, a3, s3, a4, s4
	add	a1, t0, zero

	/* Preload HART details
	 * s7 -> HART Count
	 * s8 -> HART Stack Size
	 */
	lla	a4, platform
#if __riscv_xlen > 32
	lwu	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lwu	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#else
	lw	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lw	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#endif

	/* Setup scratch space for all the HARTs*/
	lla	tp, _fw_end
	mul	a5, s7, s8    // a5 = s7 * s8 = cpu个数 * 每个cpu栈空间大小(qemu上是8K)
	add	tp, tp, a5   // 扩展空间
	/* Keep a copy of tp */
	add	t3, tp, zero
	/* Counter */
	li	t2, 1
	/* hartid 0 is mandated by ISA */
	li	t1, 0  // 从初始化 hart 0 的scratch开始
_scratch_init:
	/*
	 * The following registers hold values that are computed before
	 * entering this block, and should remain unchanged.
	 *
	 * t3 -> the firmware end address
	 * s7 -> HART count
	 * s8 -> HART stack size
	 */
	add	tp, t3, zero
	mul	a5, s8, t1
	sub	tp, tp, a5
	li	a5, SBI_SCRATCH_SIZE
	sub	tp, tp, a5   // tp指向当前hart的struct sbi_scratch起始地址

	/* Initialize scratch space */
	/* Store fw_start and fw_size in scratch space */
	lla	a4, _fw_start
	sub	a5, t3, a4
	REG_S	a4, SBI_SCRATCH_FW_START_OFFSET(tp)  // fw_start赋值
	REG_S	a5, SBI_SCRATCH_FW_SIZE_OFFSET(tp) // fw_size赋值

	/* Store R/W section's offset in scratch space */
	lla	a4, __fw_rw_offset
	REG_L	a5, 0(a4)
	REG_S	a5, SBI_SCRATCH_FW_RW_OFFSET(tp)  //  fw_rw_offset

	/* Store next arg1 in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_arg1
	REG_S	a0, SBI_SCRATCH_NEXT_ARG1_OFFSET(tp)  //  next_arg1
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Store next address in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_addr
	REG_S	a0, SBI_SCRATCH_NEXT_ADDR_OFFSET(tp)  // next_addr
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Store next mode in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_mode
	REG_S	a0, SBI_SCRATCH_NEXT_MODE_OFFSET(tp)  // next_mode
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Store warm_boot address in scratch space */
	lla	a4, _start_warm
	REG_S	a4, SBI_SCRATCH_WARMBOOT_ADDR_OFFSET(tp) // warmboot_addr
	/* Store platform address in scratch space */
	lla	a4, platform
	REG_S	a4, SBI_SCRATCH_PLATFORM_ADDR_OFFSET(tp)  // platform_addr
	/* Store hartid-to-scratch function address in scratch space */
	lla	a4, _hartid_to_scratch
	REG_S	a4, SBI_SCRATCH_HARTID_TO_SCRATCH_OFFSET(tp) // hartid_to_scratch
	/* Store trap-exit function address in scratch space */
	lla	a4, _trap_exit
	REG_S	a4, SBI_SCRATCH_TRAP_EXIT_OFFSET(tp) 		// trap_exit
	/* Clear tmp0 in scratch space */
	REG_S	zero, SBI_SCRATCH_TMP0_OFFSET(tp)   		// tmp0
	/* Store firmware options in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
#ifdef FW_OPTIONS
	li	a0, FW_OPTIONS
#else
	call	fw_options
#endif
	REG_S	a0, SBI_SCRATCH_OPTIONS_OFFSET(tp)
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Move to next scratch space */
	add	t1, t1, t2               // t1++, 下一个cpu
	blt	t1, s7, _scratch_init

	/*
	 * Relocate Flatened Device Tree (FDT)
	 * source FDT address = previous arg1
	 * destination FDT address = next arg1
	 *
	 * Note: We will preserve a0 and a1 passed by
	 * previous booting stage.
	 */
	beqz	a1, _fdt_reloc_done
	/* Mask values in a4 */
	li	a4, 0xff
	/* t1 = destination FDT start address */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_arg1
	add	t1, a0, zero
	MOV_3R	a0, s0, a1, s1, a2, s2
	beqz	t1, _fdt_reloc_done
	beq	t1, a1, _fdt_reloc_done
	/* t0 = source FDT start address */
	add	t0, a1, zero
	/* t2 = source FDT size in big-endian */
#if __riscv_xlen == 64
	lwu	t2, 4(t0)
#else
	lw	t2, 4(t0)
#endif
	/* t3 = bit[15:8] of FDT size */
	add	t3, t2, zero
	srli	t3, t3, 16
	and	t3, t3, a4
	slli	t3, t3, 8
	/* t4 = bit[23:16] of FDT size */
	add	t4, t2, zero
	srli	t4, t4, 8
	and	t4, t4, a4
	slli	t4, t4, 16
	/* t5 = bit[31:24] of FDT size */
	add	t5, t2, zero
	and	t5, t5, a4
	slli	t5, t5, 24
	/* t2 = bit[7:0] of FDT size */
	srli	t2, t2, 24
	and	t2, t2, a4
	/* t2 = FDT size in little-endian */
	or	t2, t2, t3
	or	t2, t2, t4
	or	t2, t2, t5
	/* t2 = destination FDT end address */
	add	t2, t1, t2
	/* FDT copy loop */
	ble	t2, t1, _fdt_reloc_done
_fdt_reloc_again:
	REG_L	t3, 0(t0)
	REG_S	t3, 0(t1)
	add	t0, t0, __SIZEOF_POINTER__
	add	t1, t1, __SIZEOF_POINTER__
	blt	t1, t2, _fdt_reloc_again
_fdt_reloc_done:

	/* mark boot hart done */
	li	t0, BOOT_STATUS_BOOT_HART_DONE
	lla	t1, _boot_status
	REG_S	t0, 0(t1)  // 写入BOOT_HART_DONE标记
	fence	rw, rw      // 内存屏障
	j	_start_warm  // 跳转到_start_warm

	/* waiting for boot hart to be done (_boot_status == 2) */
_wait_for_boot_hart:
	li	t0, BOOT_STATUS_BOOT_HART_DONE
	lla	t1, _boot_status
	REG_L	t1, 0(t1)
	/* Reduce the bus traffic so that boot hart may proceed faster */
	nop
	nop
	nop
	bne	t0, t1, _wait_for_boot_hart

_start_warm:
	/* Reset all registers for non-boot HARTs */
	li	ra, 0
	call	_reset_regs  // 清零通用寄存器，冲刷指令缓存

	/* Disable all interrupts */
	csrw	CSR_MIE, zero   // 禁止所有中断
	/*
	 * Only clear the MIP_SSIP and MIP_STIP. For the platform like QEMU,
	 * If we clear other interrupts like MIP_SEIP and the pendings of
	 * PLIC still exist, the QEMU may not set it back immediately.
	 */
	li	t0, (MIP_SSIP | MIP_STIP) // 清零MIP_SSIP和MIP_STIP标记位
	csrc	CSR_MIP, t0

	/* Find HART count and HART stack size */
	lla	a4, platform
#if __riscv_xlen == 64
	lwu	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lwu	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#else
	lw	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lw	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#endif
	REG_L	s9, SBI_PLATFORM_HART_INDEX2ID_OFFSET(a4)

	/* Find HART id */
	csrr	s6, CSR_MHARTID // 获取当前hartid

	/* Find HART index */
	beqz	s9, 3f
	li	a4, 0
1:
#if __riscv_xlen == 64
	lwu	a5, (s9)
#else
	lw	a5, (s9)
#endif
	beq	a5, s6, 2f
	add	s9, s9, 4
	add	a4, a4, 1
	blt	a4, s7, 1b
	li	a4, -1
2:	add	s6, a4, zero
3:	bge	s6, s7, _start_hang

	/* Find the scratch space based on HART index */
	lla	tp, _fw_end
	mul	a5, s7, s8
	add	tp, tp, a5
	mul	a5, s8, s6
	sub	tp, tp, a5
	li	a5, SBI_SCRATCH_SIZE
	sub	tp, tp, a5    // 找到当前hart对应的scratch

	/* update the mscratch */
	csrw	CSR_MSCRATCH, tp // 当前cpu对应的scratch写入CSR_MSCRATCH

	/* Setup stack */
	add	sp, tp, zero    // 设置栈帧sp

	/* Setup trap handler */
	lla	a4, _trap_handler
	csrw	CSR_MTVEC, a4   // _trap_handler写入CSR_MTVEC

	/* Initialize SBI runtime */
	csrr	a0, CSR_MSCRATCH
	call	sbi_init      // 跳转到sbi_init C函数继续初始化流程

	/* We don't expect to reach here hence just hang */
	j	_start_hang
```

## sbi_init
大致流程如下，后续还需要仔细分析每个子模块的初始化
```
lib/sbi/sbi_init.c
init_coldboot
	sbi_scratch_init  //  在栈空间找到当前hart对应的scratch，把scratch地址写入hartid_to_scratch_table指针数组index所在位置，每个hartid都在table里有一个指向struct sbi_scratch的指针
	sbi_domain_init //  root域初始化，安全相关特性
	sbi_hsm_init     // hsm扩展初始化，按照顺序启动所有harts
	sbi_platform_early_init   // 被RISC-V平台和SoC供应商轻松扩展以适应特定的硬件配置
	sbi_hart_init    // 初始化每个hart的上下文状态，包括为每个hart分配栈空间，初始化sbi scratch结构体某些字段
				// 包括固件在内存中的地址，下一个启动阶段要执行的代码入口地址，参数以及特权级等
		sbi_hart_reinit
			fp_init    //   浮点相关初始化
			delegate_traps   // 托管异常给下一级（比如linux内核）
	sbi_console_init  // 控制台初始化，之后就可以显示打印信息
	sbi_pmu_init   // CPU PMU 性能计数器初始化
	sbi_irqchip_init   // 初始化平台的中断控制器
	sbi_ipi_init   //  核间中断初始化
	sbi_tlb_init  
	sbi_timer_init   // 定时器
	sbi_ecall_init   // 系统调用
	sbi_domain_finalize   //
	sbi_hart_pmp_configure  // pmp配置，保护物理内存访问的机制
	sbi_platform_final_init   // 平台初始化，取决于具体的厂商实现
	sbi_boot_print_general  
	sbi_boot_print_domains
	sbi_boot_print_hart
	wake_coldboot_harts
	sbi_hsm_hart_start_finish(scratch, hartid);   
		sbi_hart_switch_mode(hartid, next_arg1, next_addr, next_mode, false);  //从machine mode切换到supervisor mode

__asm__ __volatile__("mret" : : "r"(a0), "r"(a1));  // a0 是coodboot hart id ;  a1是 scratch->next_arg1，即fdt地址
```

##### sbi_hart_switch_mode
```
void __attribute__((noreturn))
sbi_hart_switch_mode(unsigned long arg0, unsigned long arg1,
		     unsigned long next_addr, unsigned long next_mode,
		     bool next_virt)
{
#if __riscv_xlen == 32
	unsigned long val, valH;
#else
	unsigned long val;
#endif

	switch (next_mode) {
	case PRV_M:
		break;
	case PRV_S:    // 下一阶段为linux内核镜像，特权模式S(Supervisor特权级)
		if (!misa_extension('S'))
			sbi_hart_hang();
		break;
	case PRV_U:
		if (!misa_extension('U'))
			sbi_hart_hang();
		break;
	default:
		sbi_hart_hang();
	}

	val = csr_read(CSR_MSTATUS);
	sbi_printf("1 mstatus val 0x%lx\n", val);
	val = INSERT_FIELD(val, MSTATUS_MPP, next_mode); // 下一阶段的特权模式插入val临时变量
	sbi_printf("2 mstatus val 0x%lx\n", val);
	val = INSERT_FIELD(val, MSTATUS_MPIE, 0);   // mstatus寄存器MPIE字段写入0，即上一个中断使能位写入0，禁中断
	sbi_printf("3 mstatus val 0x%lx\n", val);
#if __riscv_xlen == 32
	if (misa_extension('H')) {
		valH = csr_read(CSR_MSTATUSH);
		valH = INSERT_FIELD(valH, MSTATUSH_MPV, next_virt);
		csr_write(CSR_MSTATUSH, valH);
	}
#else
	if (misa_extension('H'))
		val = INSERT_FIELD(val, MSTATUS_MPV, next_virt);
#endif
	sbi_printf("4 mstatus val 0x%lx\n", val);
	csr_write(CSR_MSTATUS, val);      // 最终val写入mstatus寄存器
	csr_write(CSR_MEPC, next_addr); // 执行mret时，PC会跳转到mepc中保存的next_addr，即下一阶段地址

	if (next_mode == PRV_S) {
		csr_write(CSR_STVEC, next_addr);   // 把next_addr写入stvec寄存器
		csr_write(CSR_SSCRATCH, 0); // 清零sscratch
		csr_write(CSR_SIE, 0);  // 禁中断
		csr_write(CSR_SATP, 0); // 禁分页
	} else if (next_mode == PRV_U) {
		if (misa_extension('N')) {
			csr_write(CSR_UTVEC, next_addr);
			csr_write(CSR_USCRATCH, 0);
			csr_write(CSR_UIE, 0);
		}
	}

	sbi_printf("a0 0x%lx, a1 0x%lx, next_addr 0x%lx\n", arg0, arg1, next_addr);

	register unsigned long a0 asm("a0") = arg0;
	register unsigned long a1 asm("a1") = arg1;
	__asm__ __volatile__("mret" : : "r"(a0), "r"(a1)); // 跳转到下一启动阶段，linux内核镜像
	__builtin_unreachable();
}
```

##### mret指令
在RISC-V架构中，mret指令和mepc寄存器协同工作，用于实现异常处理和上下文切换。  

mepc寄存器（Machine Exception Program Counter）是一个特殊的寄存器，用于存储异常处理程序的地址。  
当发生异常时，处理器会将当前指令的地址保存到mepc寄存器中，并跳转到异常处理程序。  

mret指令（Machine Exception Return）用于从异常处理程序返回到先前的执行状态。  
当异常处理程序完成后，通过执行mret指令，处理器会将mepc寄存器中保存的地址加载到程序计数器（PC）中，从而恢复到先前被中断的指令的执行。

##### amoadd.w a6, a7, (a6)
_try_lottery阶段执行该指令选择boot cpu，这条指令是 RISC-V 指令集中的一条原子操作指令  

具体解释如下：  
amoadd.w: 这是原子加法指令的助记符，amo 表示原子操作，add 表示执行加法操作，.w 表示操作的数据宽度为一个字（32位）。  
a6、a7: 这是 RISC-V 指令集中的通用寄存器。a6 是目标地址寄存器，用于指定内存地址；a7 是操作数寄存器，用于提供要与内存中的数据相加的值。  
(a6): 这是间接寻址的方式，表示使用 a6 中存储的地址所指向的内存位置的值。  

执行该指令的操作如下：  
从内存中读取地址为 a6 的字（32位）的值。  
将该值与寄存器 a7 的值相加。  
将相加的结果存回寄存器 a6 和内存中的地址为 a6 的位置。  

这个指令可以用于实现原子的加法操作，确保在多线程或多核环境中的并发执行时，不会发生数据竞争和不一致的情况。

##### 重定位
编译链接后的elf的数据段没有办法做到地址无关，它可能会包含对绝对地址的引用，对于这种绝对地址的引用，必须在装载时将其重定位。  
`__rel_dyn_start` 和 `__rel_dyn_end`之间的数据就是所有重定位表项。   

## 参考
[opensbi 源码](https://github.com/riscv-software-src/opensbi)
