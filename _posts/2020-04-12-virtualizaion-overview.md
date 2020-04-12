---
layout:     post
title:      Virtualization Overview
subtitle:   虚拟化概述
date:       2020-04-12
author:     iceberg
header-img: img/bluelinux.jpg
catalog: true
tags:
    - virtualization
    - kvm

---
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-04-12-virt-kvm-1.jpeg)
## 虚拟化架构  
虚拟化架构可分为可虚拟化架构和不可虚拟化架构  
判断一个架构是否可虚拟化，其核心就在于该架构对敏感指令的支持上。  
系统虚拟化又称平台虚拟化。

### Intel VT-x 和 敏感指令
Intel VT ，Intel Virtualization Technology，intel虚拟化技术的通用名称  
包含VT-x x86处理器，VT-i 安腾处理，一级VT-d 支持I/O虚拟化 (direct I/O).

Intel VT-x可以视为一个硬件功能部件，用于监测敏感指令的执行，一旦检测到CPU执行敏感指令就切换到hypervisor管理者程序。hypervisor是运行在物理机上的客户机监控程序．

有两类敏感指令:
* 意图改变系统资源状态的控制敏感类指令，这类指令会影响到物理机的运行  
* 和系统资源状态协同运作的行为敏感类指令，这类指令在虚拟机上的执行结果不同于在物理机上直接执行

虚拟机上的程序一旦毫无阻碍的执行敏感指令，会给系统和管理程序带来严重的问题。  
cpu必须能够检测到这些指令的执行，然后通知hypervisor代表虚拟机程序去执行这些指令。

**本质上x86是非虚拟化架构的cpu。**  x86cpu设计之初没有考虑到虚拟化的支持，存在一些敏感指令在执行的时候，cpu不能及时检测到这类指令性。所以一旦直接在物理机上执行，会带来严重问题。

**Intel VT-x就是针对该问题提出的硬件解决方案。**  给cpu添加一个了新的模式，guest mode。
一旦cpu监测到敏感指令的执行就切换运行模式，通知hypervisor代表发起该指令的虚拟机执行该指令。

## 三种虚拟化方式
* 完全虚拟化 full virtualization  
依赖于二进制转换技术binary translation  
陷入并模拟敏感指令的执行 存在性能问题  
客户机运行在ring 1；vmm运行在ring 0

* 类虚拟化 paravirtualization  
需要修改客户机操作系统代码,使用hypercall执行特权指令  
客户机操作系统调用hypervisor提供的hypercall-API  
客户机运行在ring 0；vmm运行在ring 0

* 硬件辅助虚拟化 hardware assisted virtualization  
一种平台虚拟化技术, 结合了full virtualization和hardware capabilities.  
基于x86架构的硬件虚拟化技术包括了　Intel VT-x/i/d　和 AMD-V  
添加了新的处理器模式guest mode  
无需修改客户机操作系统，有很好的性能，现代的虚拟化技术流利用了这种特性,比如KVM  
客户机运行在ring 0; vmm运行在ring -1  

vmm 主要负责管理客户机需要的各种资源，根据客户机的配置分配相应的资源  
不论采用何种虚拟化方式，vmm对物理资源的虚拟可以归结为三个主要任务:  
* 处理器虚拟化  
* 中断虚拟化
* 内存虚拟化  
* I/O虚拟化  

因为访问内存或者I/O的指令本身就是敏感指令，所以内存虚拟化和I/O虚拟化都依赖于处理器虚拟化的正确实现。

---
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-04-12-virt-kvm-2.jpeg)

## 虚拟化组件  
###  libvirt
libvirt提供了一个通用稳定的接口，用于虚拟机的各种管理任务，  
比如虚拟机的创建，修改，监控，控制，迁移等等。

libvirt也要负责组装参数，并向qemu-kvm进程传参，提供完整的命令行参数。
libvirt 会spawn创建出qemu进程，而qemu会负责和kvm内核模块交互创建虚拟机(使用ioctl系统调用接口过/dev/kvm设备文件进行通信)。kvm模块负责创建/dev/kvm文件。

### libvirtd服务程序
响应客户端(比如virsh/virt-manager)的请求  
也支持网络远程连接请求  
客户端和libvirtd通信是使用URI格式数据  

客户机的各种资源配置属性文件是xml类型的, 位于/etc/libvirt/qemu  
libvirtd就是用这些xml中的配置模板生成参数列表传递给qemu-kvm进程  

libvirt client通过域套接字AF_UNIX向libvirtd发送请求  
libvirtd就在/var/run/libvirt/libvirt-sock上监听连接请求。  

### qemu  
qemu负责模拟处理器和各种外设，磁盘，网络，pci，vga，串口，并行口，usb等等。  
qemu进程会打开/dev/kvm文件，使用ioctl系统调用，和内核kvm模块交互  
从本质上说，虚拟计算机系统和物理计算机系统可以是两个完全不同的ISA的系统。  

#### qemu as an emulator
使用binary translation方式
qemu可以在没有kvm配合的情况下，使用binary translation 技术，虚拟出各种架构的客户机，如powerpc,S390,x86等，但是相对于硬件辅助虚拟化并且启用kvm的情况，性能会有所降低。

#### qemu as a virtualizer
**kvm和qemu共同构建出一个完整的hypervisor，qemu负责虚拟化的用户态部分，kvm负责虚拟化的内核态部分。**  
kvm是硬件虚拟化扩展的加速器，是和cpu架构绑定到一起的。  
间接得出一个结论，**客户机系统架构和宿主机系统架构一样的情况下，才能利用处理器自带的硬件虚拟化扩展特性。**
比如，x86宿主机上创建的x86客户机就可以充分利用硬件虚拟化扩展特性提升性能。  
但是，x86宿主机上创建arm客户机就不能使用硬件虚拟化扩展特性提升性能，只能使用binary translation方式模拟，性能当然受到影响。

宿主机上可以运行多个客户机，每个客户机都对应一个qemu进程。  
客户机关机时进程就会exited/destroyed.  
每一个客户机都对应一个qemu进程，每一个vcpu对应一个线程。  
客户机的虚拟vcpu都是宿主机创建出来的posix线程。  
针对客户机的每一个vcpu，qemu相应创建一个posix thread，是一比一的关系。  

客户机使用的物理内存地址座落在qemu进程的内存虚拟地址空间。

qemu进程除了启动vcpu thread，还会启动iothread，使用select event loop处理I/O事件，比如网络分组，磁盘I/O完成等。

### KVM
intel和amd采用的是硬件辅助的完全虚拟化策略。  
主要包括两个内核模块:
1. 通用内核模块kvm.ko
2. 硬件架构相关模块  
  intel  kvm-intel.ko (flag vmx present)  
  amd  kvm-amd.ko (flag svm present)  

系统安装了kvm.ko和kvm-intel/amd.ko的情况下，就相当于把系统内核当做了hypervisor, 从而实现了虚拟化。

kvm模块创建了/dev/kvm文件，开放给上层应用qemu。  
qemu就通过该设备文件和kvm模块通信，创建、初始化和管理虚拟机的内核上下文。  


**VMX virtual machine extention**  
准确的说，Intel VT-x添加了两个程序执行模式，VMX root操作和non-root操作。  
cpu监测到敏感指令执行，就切换到VMX root，称之为VM Exit。  
hypervisor代表程序执行完敏感指令返回结果后，再继续运行VM，称之为VM Entry。  
为此，Intel又添加了两条新的指令，VT-x-VMLAUNCH 和 VT-x-VMRESUME。  
所以KVM的主要职责就是处理VM 的 Exit 和 Entry。  
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-04-12-virt-kvm-3.jpeg)

### KVM和QEMU协同
kvm只是内核的一个模块，它自己并不能创建虚拟机。必须配合用户态程序QEMU协同工作。  
QEMU本质上是个硬件模拟器。可以模拟标准的x86 个人电脑，以及其它一些架构。  
QEMU在kvm之前就已经存在了，可以没有KVM的情况下执行。

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-04-12-virt-kvm-4.jpeg)

单纯靠QEMU在用户态解释执行cpu指令，性能是很低的。满足以下三个条件，就可以极大提升性能。
1. 客户机指令可以直接在CPU上执行。
2. 指令可以在VMX non-root模式下不加修改，直接执行。
3. cpu不能直接执行的指令可以识别出来之后交给qemu模拟处理。
KVM就是基于这个想法而开发的。以最小的修改，最大化利用现有的开源软件，实现虚拟机的创建。


0. 首先kvm模块创建一个设备节点/dev/kvm。
qemu 使用 ioctl  通过 /dev/kvm 和 kvm内核模块交互，发送各种请求实现 VM功能。
1. qemu 调用 ioctl 指示 kvm 启动虚拟机。
2. kvm 执行 VM Entry，开始运行客户机。
3. 当客户机执行到敏感指令时，触发VM Exit，kvm会识别出exit的原因。
4. 如果需要qemu的干预执行IO任务或者切换任务，控制权就会转给qemu。
    一旦qemu执行完毕，再次调用ioctl系统调用，请求kvm继续运行客户机。
这就回到第一步了，周而复始。

QEMU/KVM架构  
1. KVM内核模块的实现把 linux 内核转化成了一个 hypervisor。
2. 每一个客户机都对应一个qemu进程。多个客户机运行，就有同样数量的qemu进程。
3. qemu是个多线程进程，客户机系统的每一个虚拟cpu(vcpu)都对应一个线程。
4. 从内核角度看，qemu的每一个线程都对应一普通的用户态进程。
   所以vcpu的线程调度是由内核调度器负责的，就像调度其它进程线程一样。

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2020-04-12-virt-kvm-5.jpeg)

[参考]  
Kernel-based Virtual Machine Technology  
mastering kvm virtualization  
系统虚拟化－原理与实现  
