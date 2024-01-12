---
layout:     post
title:      sched domain & group
subtitle:   调度域和调度组
date:       2024-01-11
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - sched
---

## 简介
Linux内核引入调度域（sched domain）和调度组（sched group）的目的是优化任务调度，以更好地适应多核和多处理器系统的复杂性。  
这两个概念提供了一种层次结构，允许操作系统更有效地管理和调度任务，以提高系统的整体性能和响应性。  

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2024-01-11-sched-domain-group.png)

## cpu 拓扑
分三个级别  
* Package (PKG)  
* Multi-Core Cache (MC)   
* Simultaneous multithreading  (SMT)

一个socket只可以安装一个package    
一个package里可以封装一个或者多个die
一个die上可以安装一个core或者多个core(MC)
 
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-06-20-cpu-7.jpeg)

## domain & group

**调度组**   
调度组是指把一组相关的任务（例如同一个应用程序的多个线程）进行统一管理的单位。  
在Linux内核中，CFS调度器（Completely Fair Scheduler）使用调度组来组织和管理任务。  
它允许内核为不同的任务组分配不同的CPU时间，并且在多核系统中能够更加灵活地利用多个处理器。  

**调度域**    
调度域是指对CPU资源进行分配和调度的范围。它可以包括单个处理器、多个处理器核心或者整个系统。  
调度域的作用是提供一种层次化的调度管理机制，使得CPU资源的分配能够更加灵活和高效。   
在多核系统中，调度域可以帮助内核根据不同的任务需求进行合理的调度和分配，同时也能够维护处理器之间的负载均衡。  

一个调度域包含多个调度组，系统做负载均衡时，首先需要保证的就是一个调度域中所有调度组的负载平衡，再考虑跨域的负载平衡。  
因为跨域调度的性能损耗要大于域内调度。

每个 Scheduling Domain 其实就是具有相同属性和调度策略的一组 cpu 的集合。  
并且跟据 Hyper-threading, Multi-core, SMP, NUMA architectures 这样的系统结构划分成不同的级别level。    
不同级别level之间通过指针链接在一起，从而形成一种的树状关系。  

在开启SMT或者HT的架构上，最底层第一级的base domain 涵盖(span)一个物理核心的所有的硬件线程    
每一个硬件线程在os角度来看都是一个逻辑cpu，每一个逻辑cpu就是一个group。

struct sched_domain 必须是per-cpu类型的数据，可以无锁更新。  
每一个sched domain 都涵盖(span)一定数量的cpu。 parent domain的 span 必须是child domain的超集。  
每一个sched_domain 里的任意两个sched_group的cpumask必须没有交集，或者说交集为空，即某一级domain里的某个cpu只能位于一个group里。  
每一个sched_domain 里的所有sched_group的 cpumask 合起来必须等同于这个sched_domain的span。  
每一个sched_group 都被视为一个整体，就在某一级domain里涵盖的sched groups之间进行负载均衡。

group的load等于组内所有cpu的load总和。  只有当一个group的负载失衡时才会在group之间迁移任务。  

## isolcpus参数
构建调度域层级的时候，会把`isolcpus`参数指定的 cpus 从调度域内剔除  
系统上除了内核态几个percpu类型的内核线程，其它内核线程以及用户态进程不会调度到isolcpus指定的cpu上  
```
int __init sched_init_domains(const struct cpumask *cpu_map)
{
    ...
    cpumask_and(doms_cur[0], cpu_map, housekeeping_cpumask(HK_TYPE_DOMAIN)); // 剔除隔离的cpu集合
    err = build_sched_domains(doms_cur[0], NULL);
    ...
}
```

## 调度选核
CFS调度类选核的时候都会调用到`select_task_rq_fair`，该函数有三条路径，无论走哪条都会从所在调度域层级内选择某个核。   
会使用sched_domain_span(domain)获取合法cpu集合范围。
```
select_task_rq_fair
	find_energy_efficient_cpu
	find_idlest_cpu
	select_idle_sibling
```

## 参考
https://lwn.net/Articles/80911/  
https://lwn.net/Articles/577471/  
https://www.kernel.org/doc/html/latest/scheduler/sched-domains.html  
https://static.linaro.org/connect/san19/presentations/san19-220.pdf  
