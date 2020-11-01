---
layout:     post
title:      完全公平调度
subtitle:   CFS
date:       2020-10-31
author:     iceberg
header-img: img/bluelinux.jpg
catalog: true
tags:
    - cfs
    - sched
---

--------------------------------------------------------------
## 概念

### 进程优先级
内核态角度 内核使用[0~139]  这140个数字表示140种优先级  
0 ~ 99 实时进程优先级    100 ~ 139 普通进程优先级  

用户态角度  nice值是从用户态角度看待普通进程的优先级的一种表示方式，介于[-20 ~ 19]  
nice + 120 = [100 ~ 139] ，这样可以和内核普通进程的优先级一一对应起来  
值越小，优先级越高。  

普通进程的静态优先级static_prio默认值为120，对应nice值0  
sys_nice系统调用修改的是进程的静态优先级static_prio  

```
struct task_struct {
    ...
    int     prio;    // 动态优先级
    int     static_prio;    // 静态优先级
    int    normal_prio;    // 普通优先级
    unsigned int     rt_priority;    //实时优先级
     unsigned int     policy;    // 优先级策略
    ...
}

static int effective_prio(struct task_struct *p)
{
	p->normal_prio = normal_prio(p);
	/*
	 * If we are RT tasks or we were boosted to RT priority,
	 * keep the priority unchanged. Otherwise, update priority
	 * to the normal priority:
	 */
	if (!rt_prio(p->prio))
		return p->normal_prio;
	return p->prio;
}

进程创建的时候优先级初始化
copy_process
    sched_fork
        p->prio = current->normal_prio;

nice系统调用调整静态优先级
nice
    set_user_nice
        p->static_prio = NICE_TO_PRIO(nice);
        p->prio = effective_prio(p);

```
`static_prio` 和 `rt_priority` 这两个优先级分别代表普通进程和实时进程的固有优先级属性  
`static_prio`        值越小，优先级越高；启动时分配，可以用nice() 或者 sched_setscheduler()系统调用更改，否则运行期间保持不变  
`rt_priority`       值越大，优先级越高；  
`normal_prio`      因为 static_prio 和 rt_priority 优先级的数值和优先级的高低是相反的，统一转化为normal_prio，统一成数值越小，优先级越高  
`prio`        表示进程运行阶段的有效优先级。系统中判断进程优先级时使用的是动态优先级，调度器考虑的优先级也是这个。  

普通进程 `prio = effective_prio() = normal_prio = static_prio`  
实时进程 `prio =  effective_prio() = normal_prio  = 100 -1 - rt_priority`  

### 进程权重
```
static const int prio_to_weight[40] = {
 /* -20 */     88761,     71755,     56483,     46273,     36291,
 /* -15 */     29154,     23254,     18705,     14949,     11916,
 /* -10 */      9548,      7620,      6100,      4904,      3906,
 /*  -5 */      3121,      2501,      1991,      1586,      1277,
 /*   0 */      1024,       820,       655,       526,       423,
 /*   5 */       335,       272,       215,       172,       137,
 /*  10 */       110,        87,        70,        56,        45,
 /*  15 */        36,        29,        23,        18,        15,
};

static const u32 prio_to_wmult[40] = {
 /* -20 */     48388,     59856,     76040,     92818,    118348,
 /* -15 */    147320,    184698,    229616,    287308,    360437,
 /* -10 */    449829,    563644,    704093,    875809,   1099582,
 /*  -5 */   1376151,   1717300,   2157191,   2708050,   3363326,
 /*   0 */   4194304,   5237765,   6557202,   8165337,  10153587,
 /*   5 */  12820798,  15790321,  19976592,  24970740,  31350126,
 /*  10 */  39045157,  49367440,  61356676,  76695844,  95443717,
 /*  15 */ 119304647, 148102320, 186737708, 238609294, 286331153,
};

struct load_weight {
    unsigned long weight;  // 存储权重信息
    u32 inv_weight;    //  优化数值，避免除法运算  weight * inv_weight = 2^32
};

static void set_load_weight(struct task_struct *p)
{
    int prio = p->static_prio - MAX_RT_PRIO;
    struct load_weight *load = &p->se.load;

    load->weight = scale_load(prio_to_weight[prio]);
    load->inv_weight = prio_to_wmult[prio];
}

```
各元素之间的乘积因子是1.25. 要知道为何使用该因子, 可考虑下面的例子:
两个进程A和B在nice级别0, 即静态优先级120运行, 因此两个进程的CPU份额相同, 都是50%,nice级别为0的进程, 查其权重表可知是1024. 每个进程的份额是1024/(1024+1024)=0.5, 即50%
如果进程B的优先级+1(优先级降低), 成为nice=1, 那么其CPU份额应该减少10%, 换句话说进程A得到的总的CPU应该是55%, 而进程B应该是45%. 优先级增加1导致权重减少, 即1024/1.25=820, 而进程A仍旧是1024, 则进程A现在将得到的CPU份额是1024/(1024+820=0.55, 而进程B的CPU份额则是820/(1024+820)=0.45. 这样就正好产生了10%的差值.

### 虚拟时钟 vruntime
统计CFS 任务虚拟运行时间.由每个任务的实际运行时间由相对NICE为0的权重的比例计算.
Nice 0 作为基准, 任务的vruntime等于实时运行时间real time
Nice < 0 : vrunme 增长速度慢于实际运行时间 real time
Nice > 0 : vrunme 增长速度快于实际运行时间 real time

不同权重的任务按照不同的速率增加自己的vruntime,权重高的vruntime跑得比实际时间慢, 权重低的跑的比实际时间快.
cfs调度器总是选择vruntime跑得慢的任务,这样实际造成的效果就是权重高的任务运行时间份额或者机会要高于权重低的任务

curr.nice != NICE_0_LOAD	vruntime += delta * NICE_0_LOAD/se.weight;
curr.nice =  NICE_0_LOAD	vruntime += delta;

vruntime = (delta_exec * nice_0_weight * inv_weight) >> shift
内核为了避免除法提供运算效率, 是用prio_to_wmult预先做好了除法算数,把结果填进去,实际计算的时候只有乘法和移位操作.

```
static u64 __calc_delta(u64 delta_exec, unsigned long weight, struct load_weight *lw)
{
	u64 fact = scale_load_down(weight);
	int shift = WMULT_SHIFT;

	__update_inv_weight(lw);

	if (unlikely(fact >> 32)) {
		while (fact >> 32) {
			fact >>= 1;
			shift--;
		}
	}

	fact = mul_u32_u32(fact, lw->inv_weight);

	while (fact >> 32) {
		fact >>= 1;
		shift--;
	}

	return mul_u64_u32_shr(delta_exec, fact, shift);
}

/*
 * delta /= w
 */
static inline u64 calc_delta_fair(u64 delta, struct sched_entity *se)
{
	if (unlikely(se->load.weight != NICE_0_LOAD))
		delta = __calc_delta(delta, NICE_0_LOAD, &se->load);

	return delta;
}
```


**优先级到权重的转换就是为了差别统计调度实体虚拟运行时间,尽量做到公平调度不同优先级任务.**

CFS通过每个进程的虚拟运行时间（vruntime）来衡量哪个进程最值得被调度。
CFS中的就绪队列是一棵以vruntime为键值的红黑树，虚拟时间越小的进程越靠近整个红黑树的最左端。因此，调度器每次选择位于红黑树最左端的那个进程，该进程的vruntime最小
虚拟运行时间是通过进程的实际运行时间和进程的权重（weight）计算出来的。
在CFS调度器中，将进程优先级这个概念弱化，而是强调进程的权重。一个进程的权重越大，则说明这个进程更需要运行，因此它的虚拟运行时间就越小，这样被调度的机会就越大。


### 就绪队列权重
在cpu的就绪队列rq和cfs调度器的就绪队列cfs_rq中都保存了其load_weight.  
这样不仅确保就绪队列能够跟踪记录有多少进程在运行, 而且还能将进程的权重添加到就绪队列中

由于权重仅用于调度普通进程(非实时进程), 因此只在cpu的就绪队列队列rq和cfs调度器的就绪队列cfs_rq上需要保存其就绪队列的信息, 而实时进程的就绪队列rt_rq和dl_rq 是不需要保存权重的.

就绪队列的权重存储的其实就是队列上所有进程的权重的总和, 因此每次进程被加到就绪队列的时候, 就需要在就绪队列的权重中加上进程的权重, 同时由于就绪队列的不是一个单独被调度的实体, 也就不需要优先级到权重的转换, 因而其不需要权重的重除字段, 即inv_weight = 0,
因此进程从就绪队列上入队或者出队的时候, 就绪队列的权重就加上或者减去进程的权重

```
struct rq {
    ...
    struct load_weight load; /* capture load from *all* tasks on this cpu: */
    ...
}

struct cfs_rq {
    ...
    struct load_weight load;
    ...
}
static inline void update_load_add(struct load_weight *lw, unsigned long inc);
static inline void update_load_sub(struct load_weight *lw, unsigned long dec);
static inline void update_load_set(struct load_weight *lw, unsigned long w);
```

### 调度延迟
内核有一个调度延迟的概念`__sched_period`  
即保证每个可运行的进程都应该至少运行一次的某个时间间隔.   
它在sysctl_sched_latency给出, 可通过/proc/sys/kernel/sched_latency_ns控制, 默认值为18000000纳秒, 即18毫秒.

`__sched_period`确定延迟周期的长度, 通常就是 sysctl_sched_latency
但如果有更多的进程在运行, 其值有可能按比例线性扩展. 在这种情况下, 周期长度是  

`__sched_period = sysctl_sched_latency*nr_running/sched_nr_latency`

**新创建任务或者被唤醒任务入队时都需要重新统计该值**
```
static u64 __sched_period(unsigned long nr_running)
{
	if (unlikely(nr_running > sched_nr_latency))
		return nr_running * sysctl_sched_min_granularity; // 0.75ms
	else
		return sysctl_sched_latency;
}
```

### 调度实体
```
struct task_struct
{
    /*  ......  */
    struct sched_entity se;
    /*  ......  */
}

struct sched_entity {
  struct load_weight	load; 实体权重
	unsigned int		on_rq;  是否在运行队列上
	u64			exec_start;  本次调度开始执行时间
	u64			sum_exec_runtime;  总的执行时间,真实物理时间
	u64			vruntime;  总的虚拟运行时间
	u64			prev_sum_exec_runtime; 进程退出运行队列时会把sum_exec_runtime存放到这里
}
```
**单个task一定属于个调度实体sched_entity；但是一个调度实体sched_entity可能包含多个task(组调度)**

### 运行队列
每个cpu对应一个struct rq结构体 `DEFINE_PER_CPU(struct rq, runqueues);`  
每个rq结构体包含两个就绪队列，分别是cfs(普通进程) 和rt(实时进程)就绪队列  
```
struct rq  {
  nr_running 可运行的进程总数，包含普通进程和实时进程；任务enqueue时 ++; 任务dequeu时--
  load         所有task的load 总和
  cpu_load  历史负载记录
  cfs / rt   CFS队列和RT队列
  curr    当前正在运行的task
  idle    指向idle线程
  clock   运行时钟总数
  clock_task  开启中断统计的话，就会剔除花在中断上的时间  
}
```
-------------------------------------------------------------

## 调度
### CFS调度时机
1. 调度实体的状态转换的时刻：进程终止、进程睡眠等，广义上还包括进程的创建(fork)；  
2. 当前调度实体的时机运行时间大于理想运行时间（delta_exec > ideal_runtime）,这一步在时钟中断 处理函数中完成
3. 调度实体主动放弃CPU，直接调度schedule函数，放弃CPU
4. 调度实体从中断、异常及系统调用返回到用户态时(不启用内核抢占)，检查是否需要调度

### 更新vruntime
进程enqueue/dequeue,创建,唤醒,调度的时候都需要更新任务的vruntime  
周期性调度器也要更新vruntime  
```
/*
 * Update the current task's runtime statistics.
 */
static void update_curr(struct cfs_rq *cfs_rq)
{
	struct sched_entity *curr = cfs_rq->curr;
	u64 now = rq_clock_task(rq_of(cfs_rq)); // 从队列中获取时钟
	u64 delta_exec;

	delta_exec = now - curr->exec_start;  // 上次更新和本次更新 时间戳差值

	curr->exec_start = now;    // 更新启动时间戳

	curr->sum_exec_runtime += delta_exec;  // 计入总的实际运行时间

	curr->vruntime += calc_delta_fair(delta_exec, curr);  // 更新虚拟运行时间
	update_min_vruntime(cfs_rq); // 更新队列 min_vruntime

  ...
}

static void update_min_vruntime(struct cfs_rq *cfs_rq)
{
	u64 vruntime = cfs_rq->min_vruntime;

	if (cfs_rq->curr)
		vruntime = cfs_rq->curr->vruntime;

	if (cfs_rq->rb_leftmost) {
		struct sched_entity *se = rb_entry(cfs_rq->rb_leftmost,
						   struct sched_entity,
						   run_node);

		if (!cfs_rq->curr)
			vruntime = se->vruntime;
		else
			vruntime = min_vruntime(vruntime, se->vruntime);
	}

	/* ensure we never gain time by being placed backwards. */
	cfs_rq->min_vruntime = max_vruntime(cfs_rq->min_vruntime, vruntime);
  ...
}
```
**update_min_vruntime依据当前进程和待调度的进程的vruntime值, 设置出一个可能的vruntime值, 但是只有在这个可能的vruntime值大于就绪队列原来的min_vruntime的时候, 才更新就绪队列的min_vruntime, 利用该策略, 内核确保min_vruntime只能增加, 不能减少.**

### vruntime特殊处理
新创建的进程和睡眠后苏醒的进程为了保证他们的vruntime与系统中进程的vruntime差距不会太大  
会使用place_entity来设置其虚拟运行时间vruntime, 在place_entity中重新设置vruntime值，以cfs_rq->min_vruntime值为基础，给予一定的补偿,但不能补偿太多.  
这样由于休眠进程在唤醒时或者新进程创建完成后会获得vruntime的补偿，所以它在醒来和创建后有能力抢占CPU是大概率事件，  
这也是CFS调度算法的本意，即保证交互式进程的响应速度，因为交互式进程等待用户输入会频繁休眠

但是这样子也会有一个问题, 我们是以某个cfs就绪队列的min_vruntime值为基础来设定的,  
在多CPU的系统上，不同的CPU的负载不一样，有的CPU更忙一些，而每个CPU都有自己的运行队列，每个队列中的进程的vruntime也走得有快有慢，  
比如我们对比每个运行队列的min_vruntime值，都会有不同, 如果一个进程从min_vruntime更小的CPU (A) 上迁移到min_vruntime更大的CPU (B) 上，  
可能就会占便宜了，因为CPU (B) 的运行队列中进程的vruntime普遍比较大，迁移过来的进程就会获得更多的CPU时间片。这显然不太公平  

同样的问题出现在刚创建的进程上, 还没有投入运行, 没有加入到某个就绪队列中, 它以某个就绪队列的min_vruntime为基准设置了虚拟运行时间, 但是进程不一定在当前CPU上运行, 即新创建的进程应该是可以被迁移的.

CFS是这样做的：
1. 当进程从一个CPU的运行队列中出来 (dequeue_entity) 的时候，它的vruntime要减去队列的min_vruntime值
2. 而当进程加入另一个CPU的运行队列 ( enqueue_entiry) 时，它的vruntime要加上该队列的min_vruntime值
3. 当进程刚刚创建以某个cfs_rq的min_vruntime为基准设置其虚拟运行时间后，也要减去队列的min_vruntime值
这样，进程从一个CPU迁移到另一个CPU之后，vruntime保持相对公平。

**减去min_vruntime的情况如下**
```
dequeue_entity()：
    if (!(flags & DEQUEUE_SLEEP))
        se->vruntime -= cfs_rq->min_vruntime;

task_fork_fair():
    se->vruntime -= cfs_rq->min_vruntime;

switched_from_fair():
    if (!se->on_rq && p->state != TASK_RUNNING)
    {
        /*
         * Fix up our vruntime so that the current sleep doesn't
         * cause 'unlimited' sleep bonus.
         */
        place_entity(cfs_rq, se, 0);
        se->vruntime -= cfs_rq->min_vruntime;
    }
```

**加上min_vruntime的情形**
```
enqueue_entity:
    if (!(flags & ENQUEUE_WAKEUP) || (flags & ENQUEUE_WAKING))
        se->vruntime += cfs_rq->min_vruntime;

attach_task_cfs_rq:

if (!vruntime_normalized(p))
```
```
static void
place_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int initial)
{
	u64 vruntime = cfs_rq->min_vruntime;

	/*
	 * The 'current' period is already promised to the current tasks,
	 * however the extra weight of the new task will slow them down a
	 * little, place the new task so that it fits in the slot that
	 * stays open at the end.
	 */
	if (initial && sched_feat(START_DEBIT))
		vruntime += sched_vslice(cfs_rq, se);  //新创建进程惩罚

	/* sleeps up to a single latency don't count. */
	if (!initial) {
		unsigned long thresh = sysctl_sched_latency;

		/*
		 * Halve their sleep time's effect, to allow
		 * for a gentler effect of sleepers:
		 */
		if (sched_feat(GENTLE_FAIR_SLEEPERS))
			thresh >>= 1;

		vruntime -= thresh;  // 唤醒进程补偿
	}

	/* ensure we never gain time by being placed backwards. */
	se->vruntime = max_vruntime(se->vruntime, vruntime);
}
```

### 周期性调度器
基于时钟中断, 每秒钟执行次数由CONFIG_HZ指定, 类似于心跳
```
void scheduler_tick(void)
{
	int cpu = smp_processor_id();
	struct rq *rq = cpu_rq(cpu);
	struct task_struct *curr = rq->curr;

	sched_clock_tick();

	raw_spin_lock(&rq->lock);
	update_rq_clock(rq); // 更新 rq->clock 和 rq->clock_task
	curr->sched_class->task_tick(rq, curr, 0);   // task_tick_fair
	update_cpu_load_active(rq);  // 更新队列的cpu_load[]
  ...
}

static void task_tick_fair(struct rq *rq, struct task_struct *curr, int queued)
{
	struct cfs_rq *cfs_rq;
	struct sched_entity *se = &curr->se;

	for_each_sched_entity(se) {
		cfs_rq = cfs_rq_of(se);
		entity_tick(cfs_rq, se, queued);  
	}
  ...
}

static void
entity_tick(struct cfs_rq *cfs_rq, struct sched_entity *curr, int queued)
{
	/*
	 * Update run-time statistics of the 'current'.
	 */
	update_curr(cfs_rq); // 更新vruntime

	/*
	 * Ensure that runnable average is periodically updated.
	 */
	update_load_avg(curr, 1);
	update_cfs_shares(cfs_rq);

	if (cfs_rq->nr_running > 1)
		check_preempt_tick(cfs_rq, curr); // 根据运行时间检查当前进程是否需要被调度出去
}

```
如果开启中断耗时统计的话，则clock_task减去了系统软中断和硬中断的时间clock_task  
否则clock == clock_task

check_preempt_tick(cfs_rq, curr);
检查进程本次被获得CPU使用权执行的时间是否超过了它对应的ideal_runtime值，如果超过了，则将当前进程thread_info中的TIF_NEED_RESCHED标志位置位

系统中有一个进程最少运行时间sysctl_sched_min_granularity(0.75ms),如果进程实际运行时间小于这个时间,也不需要调度.

### 主调度器
`__schedule`
```
static void __sched notrace __schedule(bool preempt)
{
	struct task_struct *prev, *next;
	unsigned long *switch_count;
	struct rq *rq;
	int cpu;

  ...

	if (task_on_rq_queued(prev))
		update_rq_clock(rq);

	next = pick_next_task(rq, prev);  // 从就绪队列选择一个最合适的进程next
	clear_tsk_need_resched(prev); // 清除TIF_NEED_RESCHED标记
	clear_preempt_need_resched();
	rq->clock_skip_update = 0;

	if (likely(prev != next)) {
		rq->nr_switches++;
		rq->curr = next;
		++*switch_count;

		rq = context_switch(rq, prev, next); // 切换到next进程运行
		cpu = cpu_of(rq);
	} else {
		lockdep_unpin_lock(&rq->lock);
		raw_spin_unlock_irq(&rq->lock);
	}

	balance_callback(rq);  // 负责均衡
}
```

`pick_next_task -> pick_next_task_fair -> pick_next_entity`  
负责选出最优next进程,如果cfs_rq->nr_running == 0,就会选择idle进程  

`context_switch -> switch_mm` 用户态进程地址空间切换,架构相关  
`context_switch -> switch_to -> __switch_to`  负责架构相关寄存器上下文切换

### 选择最优进程运行
`pick_next_entity`  
当判定运行进程是否要被新进程抢占时，内核确保被抢占者至少已经运行了某一最小时间限额   `sysctl_sched_wakeup_granularity  (gran)`

`pick_next_entity` 新选出来的 left 进程要和cfs_rq->last(curr) 及 cfs_rq->next(curr)这两个进程PK比较，  
决定left是否要抢占cfs_rq->last 或者 cfs_rq->next ， 1 2 3里的next同时也表示last  
1. `next.vruntime <= left.vruntime`  选择next，不被left抢占，即 se == cfs_rq->next  
2. `next.vruntime - left.vruntime >  gran` 被left抢占，即 se == left  
3. `left.vruntime < next.vruntime <= left.vruntime + gran` 不被left抢占，即 se == cfs_rq->next  
**1和3保证了next/last至少执行过gran时间，否则不会被left抢占  
增加的时间缓冲gran确保了进程不至于切换得太频繁，避免了花费过多的时间用于上下文切换**

### 子进程运行时机控制
`sysctl_sched_child_runs_first`控制新建子进程是否应该在父进程之前运行.   
这通常是有益的, 特别在子进程随后会执行exec系统调用的情况下. 该参数的默认设置是1, 但可以通过`/proc/sys/kernel/sched_child_first`修改

```
static void task_fork_fair(struct task_struct *p)
{
  ...

	place_entity(cfs_rq, se, 1);

	if (sysctl_sched_child_runs_first && curr && entity_before(curr, se)) {
		swap(curr->vruntime, se->vruntime);
		resched_curr(rq);
	}

	se->vruntime -= cfs_rq->min_vruntime;
}
```
如果entity_before(curr, se), 则父进程curr的虚拟运行时间vruntime小于子进程se的虚拟运行时间, 即在红黑树中父进程curr更靠左(前), 这就意味着父进程将在子进程之前被调度. 这种情况下如果设置了sysctl_sched_child_runs_first标识, 这时候我们必须采取策略保证子进程先运行, 可以通过交换curlr和se的vruntime值, 来保证se进程(子进程)的vruntime小于curr.


### 组调度
组调度是另一种给任务调度增加公平性的途径,特别是面对任务又生成很多任务的情况。  
考虑到服务器会生成很多任务来并行处理收到的接入连接, CFS引入了组来描述这种行为而不是统一的公平对待全部任务。  
生成任务的服务器进程在组内(根据层级)共享他们的 vruntime, 而单独任务会维护自己独立的 vruntime。  
在这种办法中,单个任务接收和组粗略相等调度时间。  

假设机器上除了服务器任务,另一个用户只有一个运行中的任务。如果没有组调度,第二个用户相对于服务器会受到不公平的对待。
通过组调度, CFS会首先尝试对组公平,然后再对组内进程公平。因此两个用户都获得	50%	的	CPU。  

---------------------------------------------------------
[参考链接]  
<< 深入linux内核架构 >>  
https://www.cnblogs.com/linhaostudy/p/9946814.html  
https://cloud.tencent.com/developer/article/1370903  
https://cloud.tencent.com/developer/article/1372345  
