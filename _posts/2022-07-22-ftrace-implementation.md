---
layout:     post
title:      ftrace原理与实现
subtitle:   Ftrace Principle and Implementation
date:       2022-07-22
author:     iceberg
header-img: img/bluelinux.jpg
catalog: true
tags:
    - ftrace
---

## 编译阶段
gcc -pg -mfentry -mrecord-mcount (或者scripts/recordmcount.pl)

如果不加 -pg参数，后面两个参数就不会生效

gcc 5 added -mrecord-mcount (to do this for us)   
如果gcc支持编译参数-mrecord-mcount，那么编译器自己生成__mcount_loc section  
如果gcc不支持-mrecord-mcount，那么内核编译时会使用recordmcount.pl脚本添加__mcount_loc section  


-mfentry 的作用是在函数入口处插入一条调用__fentry__的指令，内核定义了__fentry__函数
1. ftrace的实现代码本身也是不可以被trace，避免递归；所以编译时ccflags会去掉这几个编译选项
2. inline内核函数不支持trace，会被定义成notrace，gcc会做处理，该函数头部就不会预留跳转到__fentry__的指令空间
#define notrace __attribute__((no_instrument_function))


## 链接阶段
include/asm-generic/vmlinux.lds.h
```
#ifdef CONFIG_FTRACE_MCOUNT_RECORD
#define MCOUNT_REC() . = ALIGN(8); \
   VMLINUX_SYMBOL(__start_mcount_loc) = .; \
   *(__mcount_loc) \
   VMLINUX_SYMBOL(__stop_mcount_loc) = .;
#else
#define MCOUNT_REC()
#endif
```
gdb vmlinux
```
(gdb) disassemble __fentry__
Dump of assembler code for function __fentry__:
   0xffffffff81a01960 <+0>: retq   
End of assembler dump.

(gdb) disassemble blk_update_request
Dump of assembler code for function blk_update_request:
   0xffffffff81443060 <+0>: callq 0xffffffff81a01960 <__fentry__>
   0xffffffff81443065 <+5>: push %rbp
```
objdump -d vmlinux
```
ffffffff81443060 <blk_update_request>:
ffffffff81443060: e8 fb e8 5b 00 callq ffffffff81a01960 <__fentry__>  // e8 就是call指令
ffffffff81443065: 55 push %rbp
ffffffff81443066: 40 0f b6 c6 movzbl %sil,%eax
ffffffff8144306a: 48 89 e5 mov %rsp,%rbp
ffffffff8144306d: 41 57 push %r15
```

linux@pc:~/kernel/linux-4.16.8$ sudo cat /proc/kallsyms | ag mcount  
ffffffffa6e15168 T __start_mcount_loc  
ffffffffa6e5fc20 T __stop_mcount_loc  

## 系统初始化阶段
ftrace 处理 __start_mcount_loc ~ __stop_mcount_loc 数据段，  
为每一个可被跟踪的函数地址创建一条记录，分配一个结构体struct dyn_ftrace
```
start_kernel
  ftrace_init
    // 所有可以被trace的函数地址  使用nop指令替换函数头部
    ftrace_process_locs(NULL,  __start_mcount_loc,  __stop_mcount_loc)   
          // 分配ftrace_page页面，存放struct dyn_ftrace 记录(每个可被跟踪的函数都有一条记录)  
          ftrace_allocate_pages    
          ftrace_update_code
                  ftrace_code_disable        
                          ftrace_make_nop  // 所有可被跟踪的函数头部都替换成了nop指令
```

## 动态跟踪 function tracer
   1. kernel/trace/ftrace.c|4403| <<register_ftrace_function_probe>> ret = ftrace_startup(&probe->ops, 0);                                                      
   2. kernel/trace/ftrace.c|6723| <<register_ftrace_function>> ret = ftrace_startup(ops, 0);  
   3. kernel/trace/ftrace.c|7035| <<register_ftrace_graph>> ret = ftrace_startup(&graph_ops, FTRACE_START_FUNC_RET);
```
ftrace_startup  
  __register_ftrace_function
        ftrace_update_trampoline
            arch_ftrace_update_trampoline
       create_trampoline    // 构造蹦床函数
```     
系统启动初始化时，从start_kernel一直到mark_readonly之前   
内核text文本段的指令都是可以改写的，调用过mark_readonly之后才变成只读


## 钩子函数trampoline
解析ftrace
执行命令 echo function > current_tracer && echo blk_update_request > set_ftace_filter
```
(gdb) p/x sizeof(struct pt_regs)
$2 = 0xa8
(gdb) disassemble blk_update_request
Dump of assembler code for function blk_update_request:
   0xffffffff81443060 <+0>: callq ffffffffc0000000   <trampoline function>
   0xffffffff81443065 <+5>: push %rbp   
(gdb) ptype struct pt_regs
type = struct pt_regs {
    unsigned long r15;
    unsigned long r14;
...
    unsigned long sp;
    unsigned long ss;
}
struct ftrace_ops {
 ftrace_func_t func;    // 就是function_trace_call   ffffffff81179190
 struct ftrace_ops __rcu *next;
 unsigned long flags;
 void *private;
 ftrace_func_t saved_func;
#ifdef CONFIG_DYNAMIC_FTRACE
 struct ftrace_ops_hash local_hash;
 struct ftrace_ops_hash *func_hash;
 struct ftrace_ops_hash old_hash;
 unsigned long trampoline;
 unsigned long trampoline_size;
#endif

};

function_trace_call(unsigned long ip, unsigned long parent_ip,
      struct ftrace_ops *op, struct pt_regs *pt_regs)

```

kdb中给function_trace_call打断点
```
# cat /proc/kallsyms | grep blk_update_request
ffffffff81443060 T blk_update_request   // 函数入口地址
```
```
# echo g > /proc/sysrq-trigger 
[1]kdb> bp function_trace_call
Instruction(i) BP #0 at 0xffffffff81179190 (function_trace_call)
    is enabled addr at ffffffff81179190, hardtype=0 installed=0
[1]kdb> g
[ 385.601322] INFO: NMI handler (kgdb_nmi_handler) took too long to run: 13054.935 msecs
Entering kdb (current=0x (ptrval), pid 164) on processor 1 due to Breakpoint @ 0xffffffff81179190
[1]kdb> rd
ax: 0000000000000000 bx: ffff88007b824000 cx: 0000000000000000
dx: ffffffff822e48e0 si: ffffffff8166cac4 di: ffffffff81443060   // dx 即指向function_trace_call的第三个参数  ftrace_ops* 的指针；di 即第一个参数，即被跟踪的函数blk_update_request入口地址
bp: ffff88007fd03df0 sp: ffff88007fd03d40 r8: 0000000000000000
r9: 0000000000000000 r10: ffff88007b824000 r11: 0000000000000800
r12: ffff88007c3f8800 r13: 0000000000000000 r14: 0000000000000000
r15: ffff88007c271938 ip: ffffffff81179190 flags: 00000286 cs: 00000010
ss: 00000018 ds: 00000018 es: 00000018 fs: 00000018 gs: 00000018
[1]kdb> md ffffffff822e48e0 1
0xffffffff822e48e0 ffffffff81179190 ffffffff82442a60 ........`*D.....   // ffffffff81179190 即function_trace_call的函数入口地址   即ftrace_ops->func内容
[1]kdb> md ffffffff822e48e0+( 0xa0 - 0x10)           // 0xa0 即struct ftrace_ops的结构体大小，减去0x10就是ftrace_ops->trampoline的存储位置
0xffffffff822e4970 ffffffffc0000000 00000000000000b3 ................   // ffffffffc0000000就是trampoline的函数入口地址
[1]kdb> 0xffffffff81443060
0xffffffff81443060 = 0xffffffff81443060 (blk_update_request)
[1]kdb> 0xffffffff8166cac4
0xffffffff8166cac4 = 0xffffffff8166cac4 (scsi_end_request+0x34)
[1]kdb> bt
Stack traceback for pid 164
0x (ptrval) 164 1 1 1 R 0x (ptrval) *sh
Call Trace:
 <IRQ>
 ? 0xffffffffc0000077
 ? __wake_up_common_lock+0x8e/0xc0
 ? blk_update_request+0x5/0x2e0
 ? tty_port_default_wakeup+0x27/0x30
 blk_update_request+0x5/0x2e0
 scsi_end_request+0x34/0x210
 ? blk_update_request+0x5/0x2e0
 ? scsi_end_request+0x34/0x210
 scsi_io_completion+0x1d3/0x650
 scsi_finish_command+0xdc/0x130
 scsi_softirq_done+0x142/0x160
 blk_done_softirq+0x91/0xc0
 __do_softirq+0xf2/0x288
 irq_exit+0xb6/0xc0
 smp_call_function_single_interrupt+0x40/0xd0
 call_function_single_interrupt+0xf/0x20
 </IRQ>
....
[1]kdb> mds 0xffff88007fd03d40+0xa0   // 当前function_trace_call被断点断住后%rsp为0xffff88007fd03d40
0xffff88007fd03de0 0000000000000000 ........
0xffff88007fd03de8 ffff88007fd03df8 .=......
0xffff88007fd03df0 ffff88007fd03e00 .>......
0xffff88007fd03df8 ffffffff81443065 blk_update_request+0x5  
0xffff88007fd03e00 ffff88007fd03e60 `>......
0xffff88007fd03e08 ffffffff8166cac4 scsi_end_request+0x34  
0xffff88007fd03e10 ffff88007fd03e60 `>......
0xffff88007fd03e18 ffffffff81443065 blk_update_request+0x5    //  ip      function_trace_call执行完之后的返回地址，blk_update_request入口第二条指令
0xffff88007fd03e20 ffffffff8166cac4 scsi_end_request+0x34  // parent_ip 
```


**scsi_end_request ---> blk_update_request ----> trampoline_func  ---> function_call_trace**

scsi_end_request 调用  blk_update_request 并且把call指令之后的下一条指令地址入栈   
位置就是0xb0(%rsp)  (parent_ip)  

blk_update_request 被跟踪所以入口处第一条指令就是call  tampoline_func   
把call指令之后的下一条指令地址入栈  位置就是0xa8(%rsp) (ip)  

涉及到三个函数连续两次call调用，所以连续入栈两个返回地址，分别是parent_ip 和 ip  
ip即 blk_update_request 入口处第二条指令地址   

x86_64 传参ABI顺序: %rdi % rsi %rdx %rcx %r8 %r9  
```
0xffffffffc0000000: sub $0xa8,%rsp                // 当前上下文的pt_regs结构体需要入栈保存便于kprobe 获取参数，kprobe探测点位于函数入口时也会基于ftrace机制
0xffffffffc0000007: mov %rax,0x50(%rsp)
0xffffffffc000000c: mov %rcx,0x58(%rsp)      // 参数入栈
0xffffffffc0000011: mov %rdx,0x60(%rsp)
0xffffffffc0000016: mov %rsi,0x68(%rsp)
0xffffffffc000001b: mov %rdi,0x70(%rsp)
0xffffffffc0000020: mov %r8,0x48(%rsp)
0xffffffffc0000025: mov %r9,0x40(%rsp)
0xffffffffc000002a: movq $0x0,0x78(%rsp)
0xffffffffc0000033: mov %rbp,%rdx
0xffffffffc0000036: mov %rdx,0x20(%rsp)
0xffffffffc000003b: mov 0xb0(%rsp),%rsi    // function_trace_call 的 参数2( parent_ip )就保存在0xb0(%rsp)，parent_ip 就是调用blk_update_request的函数
0xffffffffc0000043: mov 0xa8(%rsp),%rdi    // function_trace_call 的 参数1 (ip) 就保存在0xa8(%rsp)     ip 就是blk_update_request入口处第二条指令 (跳过5个字节的nop指令)
0xffffffffc000004b: mov %rdi,0x80(%rsp)
0xffffffffc0000053: sub $0x5,%rdi                //   ip - 0x5 就是blk_update_request 入口第一条指令，也就是被跟踪前nop指令位置
0xffffffffc000005f: mov %rcx,0x98(%rsp)
0xffffffffc0000067: mov 0x55(%rip),%rdx # 0xffffffffc00000c3
0xffffffffc000006e: lea (%rsp),%rcx   //   (参数4)
0xffffffffc0000072: movq $0x0,0x88(%rsp)
```

## 动态替换函数头
```
ftrace_replace_code(k5.8)
    case FTRACE_UPDATE_MODIFY_CALL:
    // ftrace_get_addr_new(rec) == 0xffffffffc0000000 钩子函数 ，返回的new是个相对地址
    new = ftrace_call_replace(rec->ip, ftrace_get_addr_new(rec));  
    text_poke_queue
        text_poke_bp_batch
            text_poke(text_poke_addr(&tp[i]), tp[i].text, INT3_INSN_SIZE);  // 被跟踪函数入口写入call 钩子函数的指令

ftrace_replace_code
    add_update
        add_update_call(rec, ftrace_addr); // convert nop to call
            new = ftrace_call_replace(ip, addr);
            add_update_code(ip, new);
```
function tracer 使能stack trace　解析钩子函数  
echo 1 > options/func_stack_trace  之后 trampoline 调用的是　function_stack_trace_call (之前调用的是function_trace_call)

-------------------------------------------------------------------------------------
# 动态跟踪 function graph tracer
利用两个钩子函数  
被跟踪函数入口处钩子函数是ftrace_graph_caller  
被跟踪函数返回前钩子函数是return_to_handler  
echo function_graph　> current_tracer　把所有可以被trace的函数都会挂上这两个钩子函数  
```
blk_update_request  
    callq ftrace_graph_caller  // 把栈上存储的返回地址parent_ip 替换为return_to_handler

return_to_handler  
    ftrace_return_to_handler  
        trace.rettime = trace_clock_local();  // 获取返回时的时间

```  
