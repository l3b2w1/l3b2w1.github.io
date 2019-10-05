---
layout:     post
title:      内核浮点支持
subtitle:   arm64 arch specific
date:       2019-01-14
author:     iceberg
header-img: img/bluelinux.jpg
catalog: true
tags:
    - fpsimd
    - 浮点
    - arm64

---
# 内核浮点支持

4.4.65  arm64
[lxr](https://elixir.bootlin.com/linux/v4.4.65/source/arch/arm64/kernel/fpsimd.c)

----
## 概要说明
按运行时空间划分

* 用户态
* 内核态 : 系统调用  软中断  硬中断

----
无论是用户态还是内核态时进行浮点运算，理论上以下场合，浮点寄存器状态(FPSIMD state)都应该保存下来，后续再次执行的时候可以恢复回来

* 用户态进程或者内核线程切换
* 被中断/软中断打断
* 信号处理

---
## 内核的实现
为了降低不必要的 FSIMD state 的拷贝，内核会跟踪两个事情：

1.
针对每一个task,   添加一个字段保存cpu id 号，表示最近一次是在这个cpu上使用了浮点寄存器
每次被调度到不同的CPU上运行时，都会更新这个字段，会持续跟踪，cpu字段添加到了 fpsimd_state里面了

`*struct fpsimd_state *st = &task->thread.fpsimd_state;    st->cpu;`


 2.针对每一个cpu，添加一个 fpsimd_last_state，记住最近运行时进行了浮点运算的task，
确切的说，是task的相关的存储着FPSIMD state的指针

`per_cpu(fpsimd_last_state, cpu) = &task->thread.fpsimd_state`

有了这两项辅助，就不需要在task切换的时候就立即恢复next task 的 FPSIMD state，可以推迟到从内核空间返回到用户空间的时候
内核使用` TIF_FOREIGN_FPSTATE`标志位，用于 task 的 FPSIMD state的恢复

在task切换的时候，
`__switch_to -> fpsimd_thead_switch`会做检查:

1. 当前 cpu 记录的 fpsimd_last_state 刚好属于即将运行的 next task
2.  next task 保存的cpu 号也等于当前 cpu 号

*满足两个条件就表明，cpu 最近只有next 使用了浮点运算，并且 next 最近一次调度运行所在 cpu 就是当前 cpu，
也就是说浮点运算环境在next 上次被调度出去之后，浮点现场没有遭到破坏，可以直接使用了，也就不需要从自己 task 在内存中的备份中拷贝回浮点寄存器
这里会清零`  TIF_FOREIGN_FPSTATE` 标志位*

*否则表明，要么 next 被调度到了不用的 cpu，要么虽然还是在原来的 cpu 上运行，但是有其他 task 中途进行浮点运算时使用了浮点寄存器  无论哪种情况，next task 都需要把自己的备份数据恢复至浮点寄存器，并且置位 `TIF_FOREIGN_FPSTATE `标志位*

---

## 针对应用进程的 FPSIMD state
* 任务切换时保存浮点状态
`__switch_to -> fpsimd_thread_switch`

* 中断，软中断或者异常陷入内核，处理完之后从内核空间返回至用户空间的时候，恢复 FPSIMD state
`ret_to_user -> if (ti->flags & TIF_FOREIGN_FPSTATE) do_notify_resume -> fpsimd_restore_current_state -> fpsimd_load_state`

---
## 内核空间使用浮点运算
如果是中断或者软中断上下文

* begin中保存浮点状态到
`hardirq_fpsimdstate`或者`softirq_fpsimdstate`;
end  中恢复

* 如果是进程上下文，保存到当前task的备份空间
`current->thread.fpsimd_state;`
end 中并不会立即恢复，而是推迟到返回用户空间的时候 ```ret_to_user```


* 如果是内核线程进行浮点运算，该怎么做呢？因为这里会检查
`current->mm` 而内核线程mm字段为NULL

---
### 置位点
1. fpsimd_thread_switch 选中运行的next task 不满足两个条件
2. load_elf_binary -> ... ->fpsimd_flush_thread 进程创建的时候
3. kernel_neon_begin_partial 内核启动加密相关进行浮点运算之前
4. fpsimd_cpu_pm_notifier cpu　电源管理通知退出的时候

### 清零点
1. fpsimd_thread_switch 选中运行的next task 满足两个条件
2. ret_to_user -> do_notify_resume -> fpsimd_restore_current_state 中断/异常/系统调用 返回用户态的时候
3. sys_rt_sigreturn -> restore_sigframe -> restore_fpsimd_context -> fpsimd_update_current_state 从信号处理返回

### fpsimd state 保存点
1. 当前进程切换出去的时候 `fpsimd_thread_switch `
2. 进程创建的时候`arch_dup_task_struct -> fpsimd_preserve_current_state`
3. 处理信号的时候
`handle_signal -> ... -> preserve_fpsimd_context -> fpsimd_preserve_current_state`
4. 内核需要执行浮点运算的时候 争用FPSIMD寄存器`kernel_neon_begin_partial`
5. CPU进入PM管理的时候`fpsimd_cpu_pm_notifier`

### fpsimd state 恢复点
1. 中断/异常/系统调用 返回用户态的时候
 `ret_to_user -> do_notify_resume -> fpsimd_restore_current_state`

2. 从信号处理返回的时候
`fpsimd_update_current_state`


## 内核相关代码
一个内核使用浮点运算的例子
```
static int sha256_ce_update(struct shash_desc *desc, const u8 *data,
			    unsigned int len)
{
	struct sha256_ce_state *sctx = shash_desc_ctx(desc);

	sctx->finalize = 0;
	kernel_neon_begin_partial(28);
	sha256_base_do_update(desc, data, len,
			      (sha256_block_fn *)sha2_ce_transform);
	kernel_neon_end();

	return 0;
}
```


```
void kernel_neon_begin_partial(u32 num_regs)
{
	if (in_interrupt()) {
		struct fpsimd_partial_state *s = this_cpu_ptr(
			in_irq() ? &hardirq_fpsimdstate : &softirq_fpsimdstate);

		BUG_ON(num_regs > 32);
		fpsimd_save_partial_state(s, roundup(num_regs, 2));
	} else {
		/*
		 * Save the userland FPSIMD state if we have one and if we
		 * haven't done so already. Clear fpsimd_last_state to indicate
		 * that there is no longer userland FPSIMD state in the
		 * registers.
		 */
		preempt_disable();
		if (current->mm &&
		    !test_and_set_thread_flag(TIF_FOREIGN_FPSTATE))
			fpsimd_save_state(&current->thread.fpsimd_state);
		this_cpu_write(fpsimd_last_state, NULL);
	}
}
```


`__switch_to -> fpsimd_thread_switch(next)`
```
void fpsimd_thread_switch(struct task_struct *next)
{
 /*
  * Save the current FPSIMD state to memory, but only if whatever is in
  * the registers is in fact the most recent userland FPSIMD state of
  * 'current'.
  */
//    进程切换的时候，如果当前进程没有设置TIF_FOREIGN_FPSTATE，则保存fpsimd state
 if (current->mm && !test_thread_flag(TIF_FOREIGN_FPSTATE))
  fpsimd_save_state(&current->thread.fpsimd_state);

 if (next->mm) {
  /*
   * If we are switching to a task whose most recent userland
   * FPSIMD state is already in the registers of *this* cpu,
   * we can skip loading the state from memory. Otherwise, set
   * the TIF_FOREIGN_FPSTATE flag so the state will be loaded
   * upon the next return to userland.
   */
  struct fpsimd_state *st = &next->thread.fpsimd_state;
// next进程保存的cpu-id等于当前cpu-id 并且当前cpu的per-cpu fpsimd_last_state记录的也属于next
那么无需进行浮点寄存器的现场恢复工作，并把next的ti->flags清掉TIF_FOREIGN_FPSTATE
  if (__this_cpu_read(fpsimd_last_state) == st
      && st->cpu == smp_processor_id())
   clear_ti_thread_flag(task_thread_info(next),
          TIF_FOREIGN_FPSTATE);
  else  // 否则的话，就要设置标志为，便于后续恢复现场
   set_ti_thread_flag(task_thread_info(next),
        TIF_FOREIGN_FPSTATE);
 }
}
```

```
asmlinkage void do_notify_resume(struct pt_regs *regs,
     unsigned int thread_flags)
{
// 进程有信号需要处理
 if (thread_flags & _TIF_SIGPENDING)
  do_signal(regs);

 if (thread_flags & _TIF_NOTIFY_RESUME) {
  clear_thread_flag(TIF_NOTIFY_RESUME);
  tracehook_notify_resume(regs);
 }

// 进程有使用浮点运算
 if (thread_flags & _TIF_FOREIGN_FPSTATE)
  fpsimd_restore_current_state(); // 恢复浮点寄存器现场，并清零TIF_FOREIGN_FPSTATE

}
```

```
work_pending:
 tbnz	x1, #TIF_NEED_RESCHED, work_resched
 /* TIF_SIGPENDING, TIF_NOTIFY_RESUME or TIF_FOREIGN_FPSTATE case */
 ldr	x2, [sp, #S_PSTATE]
 mov	x0, sp	// 'regs'
 tst	x2, #PSR_MODE_MASK	// user mode regs?
 b.ne	no_work_pending	// returning to kernel
 enable_irq	// enable interrupts for do_notify_resume()
 bl	do_notify_resume　执行准备工作 恢复浮点寄存器现场
 b	ret_to_user
work_resched:
 bl	schedule
```

返回到用户层的时候，检查_TIF_WORK_MASK
```
ret_to_user:
 disable_irq	// disable interrupts
 ldr	x1, [tsk, #TI_FLAGS]
 and	x2, x1, #_TIF_WORK_MASK
 cbnz	x2, work_pending
 enable_step_tsk x1, x2
no_work_pending:
 kernel_exit 0
ENDPROC(ret_to_user)
```

保存浮点寄存器内容至当前进程浮点状态字段 current->thread.fpsimd_state
```
ENTRY(fpsimd_save_state)
    fpsimd_save x0, 8
    ret
ENDPROC(fpsimd_save_state)
```

```
.macro fpsimd_save state, tmpnr
	stp	q0, q1, [\state, #16 * 0]
	stp	q2, q3, [\state, #16 * 2]
	stp	q4, q5, [\state, #16 * 4]
	stp	q6, q7, [\state, #16 * 6]
	stp	q8, q9, [\state, #16 * 8]
	stp	q10, q11, [\state, #16 * 10]
	stp	q12, q13, [\state, #16 * 12]
	stp	q14, q15, [\state, #16 * 14]
	stp	q16, q17, [\state, #16 * 16]
	stp	q18, q19, [\state, #16 * 18]
	stp	q20, q21, [\state, #16 * 20]
	stp	q22, q23, [\state, #16 * 22]
	stp	q24, q25, [\state, #16 * 24]
	stp	q26, q27, [\state, #16 * 26]
	stp	q28, q29, [\state, #16 * 28]
	stp	q30, q31, [\state, #16 * 30]!
	mrs	x\tmpnr, fpsr
	str	w\tmpnr, [\state, #16 * 2]
	mrs	x\tmpnr, fpcr
	str	w\tmpnr, [\state, #16 * 2 + 4]
.endm
```
