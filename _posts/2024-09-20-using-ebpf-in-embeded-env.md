---
layout:     post
title:      using ebpf in embeded env
subtitle:   嵌入式环境使用ebpf
date:       2024-09-20
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    -ebpf
---


**不借助其它bpf调试工具，开发人员需要自行编写bpf 内核态类C代码和用户态C代码，  
内核态代码用于生成字节码，用户态代码负责load并attach字节码到系统**

1 借助开源库 [libbpf-bootstrap](https://github.com/libbpf/libbpf-bootstrap`) 生成示例demo    
先生成libbpf.so，再编译demo程序，最后把应用程序 （比如kprobe）打包进rootfs中  

```
git clone --recursive https://github.com/libbpf/libbpf-bootstrap
cd libbpf/src && make install
cd samples/c/ && make
```
libbpf-bootstrap/examples/c/ 目录下的文件命名规则
>基于 libbpf-bootstrap 的 BPF 程序对于源文件有一定的命名规则，   
用于生成内核态字节码的 bpf 文件以 .bpf.c 结尾，用户态加载字节码的文件以 .c 结尾，且这两个文件的 前缀必须相同。  

>基于 libbpf-bootstrap 的 BPF 程序在编译时会先将 *.bpf.c 文件编译为 对应的 .o 文件，  
然后根据此文件生成 skeleton 文件，即 *.skel.h，这个文件会包含内核态中定义的一些 数据结构，以及用于装载内核态代码的关键函数。  
在用户态代码 include 此文件之后调用对应的装载函数即可将字节码装载到内核中。

2 使用`pahole`工具基于`vmlinux`文件可以生成单独的btf文件，打包到rootfs中  
`pahole --btf_encode_detached external.btf vmlinux`

3 系统起来之后拷贝`external.btf` 到 libbpf 指定搜索的某一个位置   
比如 `cp external.btf /boot/vmlinux-5.10.0`  
```
libbpf-bootstrap/libbpf/src/btf.c

4942 struct btf *btf__load_vmlinux_btf(void)
4943 {
4944         const char *sysfs_btf_path = "/sys/kernel/btf/vmlinux";
4945         /* fall back locations, trying to find vmlinux on disk */
4946         const char *locations[] = {
4947                 "/boot/vmlinux-%1$s",
4948                 "/lib/modules/%1$s/vmlinux-%1$s",
4949                 "/lib/modules/%1$s/build/vmlinux",
4950                 "/usr/lib/modules/%1$s/kernel/vmlinux",
4951                 "/usr/lib/debug/boot/vmlinux-%1$s",
4952                 "/usr/lib/debug/boot/vmlinux-%1$s.debug",
4953                 "/usr/lib/debug/lib/modules/%1$s/vmlinux",
4954         };
```

4 最后在设备上执行 demo中的应用  
如下是运行 `libbpf-bootstrap` 中的 kprobe demo 时的输出
```
# kprobe                                                                                                                    
libbpf: loading object 'kprobe_bpf' from buffer                                                                                     
libbpf: elf: section(2) .symtab, size 240, link 1, flags 0, type=2                                                                  
libbpf: elf: section(3) kprobe/do_unlinkat, size 152, link 0, flags 6, type=1                                                       
libbpf: sec 'kprobe/do_unlinkat': found program 'do_unlinkat' at insn offset 0 (0 bytes), code size 19 insns (152 bytes)            
libbpf: elf: section(4) kretprobe/do_unlinkat, size 88, link 0, flags 6, type=1                                                     
libbpf: sec 'kretprobe/do_unlinkat': found program 'do_unlinkat_exit' at insn offset 0 (0 bytes), code size 11 insns (88 bytes)     
libbpf: elf: section(5) license, size 13, link 0, flags 3, type=1                                                                   
libbpf: license of kprobe_bpf is Dual BSD/GPL                                                                                       
libbpf: elf: section(6) .rodata, size 72, link 0, flags 2, type=1                                                                   
libbpf: elf: section(7) .relkprobe/do_unlinkat, size 16, link 2, flags 0, type=9                                                    
libbpf: elf: section(8) .relkretprobe/do_unlinkat, size 16, link 2, flags 0, type=9                                                 
libbpf: elf: section(9) .BTF, size 1449, link 0, flags 0, type=1                                                                    
libbpf: elf: section(10) .BTF.ext, size 364, link 0, flags 0, type=1                                                                
libbpf: looking for externs among 10 symbols...                                                                                     
libbpf: collected 0 externs total                                                                                                   
libbpf: map 'kprobe_b.rodata' (global data): at sec_idx 6, offset 0, flags 80.                                                      
libbpf: map 0 is "kprobe_b.rodata"                                                                                                  
libbpf: sec '.relkprobe/do_unlinkat': collecting relocation for section(3) 'kprobe/do_unlinkat'                                     
libbpf: sec '.relkprobe/do_unlinkat': relo #0: insn #12 against '.rodata'                                                           
libbpf: prog 'do_unlinkat': found data map 0 (kprobe_b.rodata, sec 6, off 0) for insn 12                                            
libbpf: sec '.relkretprobe/do_unlinkat': collecting relocation for section(4) 'kretprobe/do_unlinkat'                               
libbpf: sec '.relkretprobe/do_unlinkat': relo #0: insn #3 against '.rodata'                                                         
libbpf: prog 'do_unlinkat_exit': found data map 0 (kprobe_b.rodata, sec 6, off 0) for insn 3                                        
libbpf: object 'kprobe_bpf': failed (-22) to create BPF token from '/sys/fs/bpf', skipping optional step...                         
libbpf: loaded kernel BTF from ''                                                                                                   
libbpf: sec 'kprobe/do_unlinkat': found 2 CO-RE relocations                                                                         
libbpf: CO-RE relocating [2] struct pt_regs: found target candidate [209] struct pt_regs in [vmlinux]                               
libbpf: prog 'do_unlinkat': relo #0: <byte_off> [2] struct pt_regs.si (0:13 @ offset 104)                                           
libbpf: prog 'do_unlinkat': relo #0: matching candidate #0 <byte_off> [209] struct pt_regs.si (0:13 @ offset 104)                   
libbpf: prog 'do_unlinkat': relo #0: patched insn #0 (LDX/ST/STX) off 104 -> 104                                                    
libbpf: CO-RE relocating [7] struct filename: found target candidate [1731] struct filename in [vmlinux]                            
libbpf: prog 'do_unlinkat': relo #1: <byte_off> [7] struct filename.name (0:0 @ offset 0)                                           
libbpf: prog 'do_unlinkat': relo #1: matching candidate #0 <byte_off> [1731] struct filename.name (0:0 @ offset 0)                  
libbpf: prog 'do_unlinkat': relo #1: patched insn #3 (ALU/ALU64) imm 0 -> 0                                                         
libbpf: sec 'kretprobe/do_unlinkat': found 1 CO-RE relocations                                                                      
libbpf: prog 'do_unlinkat_exit': relo #0: <byte_off> [2] struct pt_regs.ax (0:10 @ offset 80)                                       
libbpf: prog 'do_unlinkat_exit': relo #0: matching candidate #0 <byte_off> [209] struct pt_regs.ax (0:10 @ offset 80)               
libbpf: prog 'do_unlinkat_exit': relo #0: patched insn #0 (LDX/ST/STX) off 80 -> 80                                                 
libbpf: map 'kprobe_b.rodata': created successfully, fd=3                                                                           
libbpf: failed to open '/sys/bus/event_source/devices/kprobe/type': No such file or directory                                       
libbpf: failed to open '/sys/bus/event_source/devices/kprobe/type': No such file or directory                                       
Successfully started! Please run `sudo cat /sys/kernel/debug/tracing/trace_pipe` to see output of the BPF programs.                 
.........
```

测试创建删除一个文件，然后从缓冲区读取信息
```
# touch hello
# rm hello
# mount -t debugfs nodev /sys/kernel/debug/
# cat /sys/kernel/debug/tracing/trace
# tracer: nop
#
# entries-in-buffer/entries-written: 2/2   #P:1
#
#                                _-----=> irqs-off
#                               / _----=> need-resched
#                              | / _---=> hardirq/softirq
#                              || / _--=> preempt-depth
#                              ||| /     delay
#           TASK-PID     CPU#  ||||   TIMESTAMP  FUNCTION
#              | |         |   ||||      |         |
              rm-1532    [000] d...    68.247724: bpf_trace_printk: KPROBE ENTRY pid = 1532, filename = hello

              rm-1532    [000] d...    68.247751: bpf_trace_printk: KPROBE EXIT: pid = 1532, ret = 0
```
## 参考
https://github.com/libbpf/libbpf-bootstrap  
https://eunomia.dev/zh/tutorials/0-introduce/#ebpf-go-library   
https://github.com/aquasecurity/btfhub/blob/main/docs/how-to-use-pahole.md  
