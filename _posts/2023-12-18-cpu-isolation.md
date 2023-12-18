---
layout:     post
title:      CPU Isolation
subtitle:   CPU隔离
date:       2023-12-18
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - cpu
    - housekeeping
---
## 简介
cpu隔离是个很有用的特性。目的是最小化指定cpu上的内核活动，这些内核活动可能导致延迟，降低性能。    
有些高带宽网络应用或者实时系统，对延迟和性能有特殊要求，必须独占cpu，不能受到任何其它系统活动的干扰。  
比如DPDK超高的网络带宽不允许发生丢包或者抖动。

系统活动比如，中断、timer、内核线程(比如workqueues)，页面回收等，  
这些异步的事件处理对于维护系统正常运行是必须的，因此称之为housekeeping任务。  
有些任务是绑定到cpu，有些没有绑定，没有绑定的可以在任一cpu上运行。  
这些任务有可能打断cpu上当前正在执行的业务进程，偷走业务进程的cpu cycle并且污染cache，导致进程cache miss
严重影响业务正常运行。

## housekeeping
系统上大致有以下几种系统活动
* timer
* irq/softirq
* scheduler tick
* rcu callback
* workqueues
* kthreads

对应内核中定义的这些TYPE
```
enum hk_type {
	HK_TYPE_TIMER,         //  0 定时器
	HK_TYPE_RCU,           //  1 RCU callback
	HK_TYPE_MISC,          //  2 idle rebalancing work
	HK_TYPE_SCHED,         //  3 内核未明确使用该类型
	HK_TYPE_TICK,          //  4 HZ心跳
	HK_TYPE_DOMAIN,        //  5 域调度
	HK_TYPE_WQ,            //  6 工作队列
	HK_TYPE_MANAGED_IRQ,   //  7 如果有中断的affnity cpu包含了isolcpus指定的cpu，那么这个type可以让cpu避免受到这类中断的干扰
	HK_TYPE_KTHREAD,       //  8 内核线程
	HK_TYPE_MAX
};
```
这里的每一种housekeeping事件类型都代表一个干扰因素，到来时会打断cpu当前任务，影响到关键业务

隔离指定cpu，给关键业务进程提供一个干净的cpu环境，可以通过给内核传递 `isolcpus` 和 `nohz_full` 两个参数达到目的  

- 0、1、2、4、6、8   由`nohz_full`参数负责
- 3   未起用
- 4、5、7 由`isolcpus`参数负责(默认5, 4和7可选)

本质上是把参数指定范围内的cpu上的绝大部分任务迁移到 housekeeping cpus 上。    
是绝大部分，而不是全部，因为有些per-cpu kthreads 不允许调整cpu affinity.  

**干扰只能转移，不能消除。**  

内核定义了一个全局变量 `housekeeping` 用于跟踪哪些cpu处理负责哪种每种类型的事件
```
struct housekeeping {
	cpumask_var_t cpumasks[HK_TYPE_MAX];
	unsigned long flags;   //  跟踪记录所有需要处理的TYPE
};

static struct housekeeping housekeeping;
```
每一个HK_TYPE事件都有自己的cpumask，置位的cpu需要负责处理这些类型事件  
没有置位的cpu则无需处理，除非用户配置有变化，比如绑定至少两个进程到某个cpu

## rcu_nobcs
我们知道RCU适用于多个读者和一个写者的场景。  
当所有读者都退出了临界区，RCU移除阶段的回调就会释放内存。  
这些回调可能会降低实时性能，特别是如果它们在中断上下文中运行，可能引入不可忽视的调度延迟。  

内核中实现了`CONFIG_RCU_NOCB_CPU` 配置项和 `rcu_nocbs` 参数  
可以将RCU回调移动到可在其它non time-critical CPUs上的 kthreads 中。

如果已经指定了`nohz_full`，就无需再提供 `rcu_nocbs`。

## 参数定制

**同时提供参数 `nohz_full` 与 `isolcpus`才有意义**  
**没有isolcpus，调度器可能会选择在nohz_full指定的核心上运行新的任务**  
**这会导致内核禁用nohz_full模式并回到默认的无滴答(tickless)模式（HZ滴答/秒）**


> nohz_full=4-7 isolcpus=4-7   

隔离cpu 4-7，既不会参与域调度，也没有timer中断上来，构造出干净的运行环境  

只绑定一个进程到某个cpu上， 进程就会独占该cpu，不会被调度出去，也没有timer、tick等中断干扰  

如果在cpu上绑定至少两个进程的话，中断还是会上来，因为至少还需要利用tick中断在两个进程之间调度  
就失去了 `nohz_full` 应有的意义。



## 参考索引
[cpu isolation](https://www.suse.com/c/cpu-isolation-introduction-part-1/)
