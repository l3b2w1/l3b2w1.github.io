---
layout:     post
title:      CPU Topology
subtitle:   cpu 拓扑
date:       2020-06-20
author:     iceberg
header-img: img/bluelinux.jpg
catalog: true
tags:
    - cpu
    - layout
    - topology
---

### FSB
Front Side Bus 前端总线
计算机的速度实际上取决于许多因素。这不仅仅是有多少内存或者处理器的速度;   
还有一些其他方面，其中之一就是主板的前端总线的速度，就是FSB的速度  
由于它通过芯片组连接处理器到存储器和其他外设，它充当主要连接路径，因此也被称为“系统总线”或“处理器总线”   
同样以兆赫或千兆赫来衡量，系统总线(或)前端总线的速度永远赶不上处理器的速度  
通常，前端总线的工作速度在66兆赫至800兆赫之间;与最近的主板提供的FSB速度高达800mhz。  
处理器传输数据时必须等待FSB；FSB速度越快，系统性能表现越好  

### CPU
Central Processing Units   中央处理器单元  一般就称为处理器  
重要组件  ALU FPU Cache Registers Control-Unit FSB     

### CORE
ALU FPU Cache Registers Control-Unit FSB 物理上这样一套组件合起来就可以构成一个core   
硬件设计人员把这一套必要组件称为core, 操作系统研发人员还是称为cpu
每个core可能都有自己的FSB,也可能共享FSB,和具体硬件设计有关  

### Socket
是一个硬件部件，是主板motherboard上的处理器插槽plug, 可以给处理器芯片提供电力和总线连接  
一个socket只可以插入一个处理器芯片, 主板设计好了,socket的数量就确定了, 处理器的数量也就确定了, socket和物理处理器芯片是一对一的关系  
一般同一socket上的core共享三级缓存  

*A typical motherboard socket*  
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-06-20-cpu-2.jpeg)

*Dual Sockets for Intel Xeon Processors*  
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-06-20-cpu-3.jpeg)

### SMT
Simultaneous multithreading    同时多处理  
Intel HyperThreading  和 AMD HyperTransport 的多线程技术，每一个硬件线程都会被系统认定为一个逻辑处理器CPU。
HT(HyperThread)超线程是Intel SMT同时多线程技术的实现
两个逻辑处理器使用同一个执行核，共享所有的资源，比如执行单元，cache等,交替执行指令流，最大化资源利用率，最大化性能和电源消耗.  

单个核心某个时刻只能同时执行一个应用。两个(多个)硬件线程只是意味着有两个(多个)传送带在输送指令给核心去执行。  
这些传送带最终都会汇合到一个核心上，但是同时有多个指令流在给一个核心输送指令。所以同一时刻执行任务的数量取决于核心的个数，而不是硬件线程的个数。  
来自linus 的比喻,两只手抓吃的东西往嘴里送。虽然可以同时抓，但是只能一个接一个的往嘴里送。  

*threads core socket relations*  
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-06-20-cpu-7.jpeg)

### CMP
Chip Multi Processing  芯片多处理    
随着晶体管数量的增多，发展下来，就是在一个physical processor package 中包含多个执行core    
每个核core都有拥有自己的资源，包括架构状态，寄存器，执行单元，一定级别的cache。可能共享L3cache  
一个phy内多核之间的共享资源取决于具体实现：  
a. Intel Yonah 酷睿 每个核有自己的L1cache ，共享L2 cacheb，共享FSB通信管道  
b. Intel Pentium D 奔腾D处理器 每个核都有自己独立的cache结构，以及独立的FSB通信管道    

phy可以同时支持SMT 和 CMP。这样一个phy内每个核可以有多个逻辑线程。比如，一个phy支持SMT-HT的双核处理器，可以对外表现为四个逻辑处理器，同时运行四个进程/线程。  

*CMP implementation with two cores sharing L2 cache and Bus interface*    
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-06-20-cpu-0.jpeg)

*CMP implementation with two cores, each having two logical threads. Each core has their own cache hierarchy and communication path to FSB*    
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-06-20-cpu-1.jpeg)
一个phy上多个核心之间没有共享资源的结构，调度器首先应该在一个package上的核心之间均衡负载，其次是寻找空闲的package。这样可以节省耗电，而且也不会影响性能。

### SMP
Symmetric Multi-Processors  对称多处理器  
每个处理器在系统中所处的地位和发挥的功能都是一样的,是相互对称的.  
多处理器应用最多的场合就是商用的服务器和需要处理大量计算的环境.  
所以商用主板一般都只有一个socket，比如个人电脑   
工业级服务器主板上一般有多个socket，可以插入多个物理处理器芯片   
这就设计就是SMP  

### SMP vs NUMA
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-06-20-cpu-5.jpeg)
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-06-20-cpu-6.jpeg)

---
### Intel Xeon
一个系统架构可以同时具有SMP CMP SMT 三种特性  
主板上有两个socket, 每个socket可以插入一个芯片,就是SMP  
每个芯片可以有4个core ,就是CMP  
每个core 可以有2-way 2路硬件线程 就是 SMT  
所以这个系统总共可以支持2 * 4 * 2 = 16个threads, 对操作系统来说, 对外可以表现出16个逻辑CPU  
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-06-20-cpu-4.jpeg)

### PC
```
Architecture:          x86_64
CPU op-mode(s):        32-bit, 64-bit
Byte Order:            Little Endian
CPU(s):                4
On-line CPU(s) list:   0-3
Thread(s) per core:    1
Core(s) per socket:    4
Socket(s):             1
NUMA node(s):          1
Vendor ID:             GenuineIntel
CPU family:            6
Model:                 94
Model name:            Intel(R) Core(TM) i7-6700HQ CPU @ 2.60GHz
```

**把系统CPU拓扑搞清楚了,有助于理解 调度域 shed domain 和 负载均衡 load balance**

[参考链接]  
< Chip Multi Processing aware Linux Kernel Scheduler >  
http://www.onlinecmag.com/front-side-bus-fsb-information/  
https://techgearoid.com/articles/how-many-threads-can-a-quad-core-processor-handle-at-once/  
https://techgearoid.com/articles/cpu-vs-core-vs-socket/  
