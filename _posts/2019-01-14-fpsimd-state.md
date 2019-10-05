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
`current->mm`
而内核线程mm字段为NULL

