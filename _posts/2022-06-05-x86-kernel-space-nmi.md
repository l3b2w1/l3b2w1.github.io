---
layout:     post
title:      x86 nmi
subtitle:   kernel space processing
date:       2022-06-05
author:     iceberg
header-img: img/bluelinux.jpg
catalog: true
tags:
    - nmi
    - x86
---

# x86 nmi

## 简介
NMI（Nonmaskable Interrupt）中断之所以称之为NMI的原因是：  
这种类型的中断不能被CPU的EFLAGS寄存器的IF标志位所屏蔽。  

而对于可屏蔽中断而言只要IF标志位被清理（例如：CPU执行了cli指令），那么处理器就会禁止INTR Pin和Local APIC上接收到的内部中断请求。 NMI中断有两种触发方式：  
* 外部硬件通过CPU的 NMI Pin 去触发（硬件触发）
* 软件向CPU系统总线上投递一个NMI类型中断（软件触发）

当CPU从上述两种中断源接收到NMI中断后就立即调用vector=2（中断向量为2）的处理函数来处理NMI中断。  

Intel SDM, Volume 3, Chapter 6.7 Nonmaskable Interrupt章节指出：  
当一个NMI中断处理函数正在执行的时候，处理器会block后续的NMI直到中断处理函数执行IRET返回。

## 用途
NMI作为一种debug手段，打断关中断死循环的cpu核，拿到cpu控制权，
然后在nmi handler里调用dump stack获取问题现场。  
nmi处理流程被设计实现为不可重入的。

iret指令用于从中断或者异常返回，并且会重新使能NMI。  
整个nmi流程最后执行的一条指令也是iret。一旦nmi流程执行到iret指令，就意味着nmi处理完毕。

中断或者异常发生时，硬件自动保存被中断的上下文现场到对应的栈上。  
中断或者异常处理完毕，最后执行到iret指令返回时会使用栈上保存的信息恢复被中断的执行流。

## iret的问题
现在出现的问题是，如果在NMI执行期间nmi handler触发了一个异常，那么异常处理完返回时就会到执行iret。  
而iret会重新使能nmi，这就有可能出现first nmi还没结束，就被nested nmi抢占的情况。  
并且由于cpu响应nmi是自动保存现场到固定位置(IST的栈顶位置)，这就会覆盖之前nmi保存到栈上的现场，也就是被first nmi中断的现场现在被nested破坏掉了，丢失了。  
一旦first nmi返回时就会导致系统运行出错。

因为iret指令的这么一个缺陷，nmi handler为了保证执行期间不出问题，既不能触发pagefault异常，也不能触发断点异常。  

因为不能触发pagefault就意味着nmi handler不能使用vmalloc。  
因为vmalloc实现方式是先在进程页表创建虚拟地址映射表项，而把实际物理内存的分配留到第一访问发现还没有关联物理地址的时候，这就会触发pagefault。 然后就会出现上面的问题，发生nmi嵌套。  

我们知道，加载内核模块时会使用vmalloc，模块的文本段被映射到进程虚拟地址空间，在第一次执行到时就会触发pagefault。
如果模块代码里有注册NMI handler callback，这个callkback可能会导致重入NMI。

## 解决方案
**为了让nmi handler正常执行，不被破坏，必须同时能够处理这两种异常。  
现如今的代码，解决方案方式是三份上下文拷贝。**


nmi执行期间没有发生异常的情况下，栈上三份frame内容都一样，整个nmi流程不会改变。  
一旦发生nmi嵌套，三份frame各自用途：  
1. original frame 栈顶位置特地为硬件准备的，一旦nmi上来，硬件自动保存当前被中断的上下文到这里
2. iret frame     发生nmi嵌套时，必须在first nmi执行完之后，能够继续处理嵌套的nmi，起衔接作用
3. outermost frame 起备份作用，被first nmi打断的上下文就保存在这里，  
  如果发生嵌套，就要从outermost frame拷贝到iret frame,  
  这样恢复最初被nmi打断现场的责任就交给了nested nmi

## 不发生nmi 嵌套
1. first nmi执行期间，没有发生任何异常，那么就不会发生因为执行iret指令而离开nmi context的情况，也就重新使能nmi，所以不会发生嵌套。此时栈上的三份拷贝完全一致
2. first nmi执行期间，发生了异常，那么异常返回时执行iret指令就会导致重新开启nmi，一旦有新的nmi信号捅给cpu，就会发生异常嵌套；没有新的nmi上来，则不会嵌套，此时栈上的三份拷贝完全一致。

## 发生nmi嵌套
1. first nmi执行期间，发生了异常，并且异常返回后有新的nmi信号捅给cpu，那么cpu会立即响应nested nmi
nested nmi 会修改iret frame，然后尽快返回。修改iret frame 就是为了通知first nmi，后面还有一个nmi呢，你执行完了记得拉我一把。
2. first nmi 执行结束前，会清零nmi executing标记，最后执行iret指令，就会跳转到repeate_nmi，repeate_nmi首先设置nmi executing，然后在栈上把 outermost frame拷贝到iret frame位置，outermost frame存取的就是最初被first nmi中断的现场。现在由nested nmi负责在自己执行结束后恢复最初的上下文。

```
/*
 * Here's what our stack frame will look like:
 * +---------------------------------------------------------+ <--high address
 * | original SS                                             |
 * | original Return RSP                                     |
 * | original RFLAGS                                         |
 * | original CS                                             |
 * | original RIP                                            |
 * +---------------------------------------------------------+
 * | temp storage for rdx                                    |
 * +---------------------------------------------------------+
 * | "NMI executing" variable                                |
 * +---------------------------------------------------------+
 * | iret SS          } Copied from "outermost" frame        |
 * | iret Return RSP  } on each loop iteration; overwritten  |
 * | iret RFLAGS      } by a nested NMI to force another     |
 * | iret CS          } iteration if needed.                 |
 * | iret RIP         }                                      |
 * +---------------------------------------------------------+
 * | outermost SS          } initialized in first_nmi;       |
 * | outermost Return RSP  } will not be changed before      |
 * | outermost RFLAGS      } NMI processing is done.         |
 * | outermost CS          } Copied to "iret" frame on each  |
 * | outermost RIP         } iteration.                      |
 * +---------------------------------------------------------+
 * | pt_regs                                                 |
 * +---------------------------------------------------------+ <--low address
 */
 ```

------------------------------------------------------------------------------

## 汇编内核态处理走读

**arch/x86/entey/entry_64.S**

硬件自动保存的NMI栈帧大小为40字节 SS + Return RSP + RFLAGS + CS + RIP
```
1193     /* Use %rdx as our temp variable throughout */
1194     pushq   %rdx   // ---------------------2
1195       
1196     testb   $3, CS-RIP+8(%rsp)  // ---------------------3
1197     jz  .Lnmi_from_kernel    // 判断发生nmi时，地址空间处于内核态还是用户态
... // skip userspace           // ---------------------4
... // skip userspace
.Lnmi_from_kernel:
	/*
	 * Here's what our stack frame will look like:
	 * +---------------------------------------------------------+ <------ high address  NMI Stack的首地址，nmi上来时，HW自动压栈
	 * | original SS                                             |
	 * | original Return RSP                                     |
	 * | original RFLAGS                                         |
	 * | original CS                                             |
	 * | original RIP                                            |
	 * +---------------------------------------------------------+
	 * | temp storage for rdx                                    |
	 * +---------------------------------------------------------+  <------ RSP	nested_nmi	: 	addq    $(6*8), %rsp   /* Put stack back */
	 * | "NMI executing" variable                                |
	 * +---------------------------------------------------------+	<------ RSP	nested_nmi	:	subq    $8, %rsp
	 * | iret SS          } Copied from "outermost" frame        |
	 * | iret Return RSP  } on each loop iteration; overwritten  |
	 * | iret RFLAGS      } by a nested NMI to force another     |
	 * | iret CS          } iteration if needed.                 |
	 * | iret RIP         }                                      |
	 * +---------------------------------------------------------+ 	<------ RSP nested_nmi	:	pushq   $repeat_nmi (nmi_retore清零NMI-executing的时候，rsp指向这里)
	 * | outermost SS          } initialized in first_nmi;       |
	 * | outermost Return RSP  } will not be changed before      |
	 * | outermost RFLAGS      } NMI processing is done.         |
	 * | outermost CS          } Copied to "iret" frame on each  |
	 * | outermost RIP         } iteration.                      |
	 * +---------------------------------------------------------+
	 * | pt_regs                                                 |
	 * +---------------------------------------------------------+ <------ low address
	 */

   1310         /*
   1311          * Determine whether we're a nested NMI.
   1312          *
   1313          * If we interrupted kernel code between repeat_nmi and
   1314          * end_repeat_nmi, then we are a nested NMI.  We must not
   1315          * modify the "iret" frame because it's being written by
   1316          * the outer NMI.  That's okay; the outer NMI handler is
   1317          * about to about to call do_nmi anyway, so we can just
   1318          * resume the outer NMI.
   1319          */
   1320
   1321         movq    $repeat_nmi, %rdx     // --------------------- 5
   1322         cmpq    8(%rsp), %rdx	// $rsp + 8 位置存储的是被NMI打断现场的RIP，由硬件自动压入栈
   1323         ja      1f		// repeat_nmi > RIP，跳转到1f 继续判断；否则 repeate_nmi <= RIP，RIP有可能位于区间 [repeat_nmi ~ end_repeat_nmi]，不跳转，继续判断
   1324         movq    $end_repeat_nmi, %rdx	//  repeate_nmi <= RIP < end_repeat_nmi，跳出去nested_nmi_out；否则执行1f位置，继续判断
   1325         cmpq    8(%rsp), %rdx
   1326         ja      nested_nmi_out
   1327 1:
   1328
   1329         /*
   1330          * Now check "NMI executing".  If it's set, then we're nested.
   1331          * This will not detect if we interrupted an outer NMI just
   1332          * before IRET.
   1333          */
   1334         cmpl    $1, -8(%rsp)		// ---------------------6
   1335         je      nested_nmi    // 判断nmi excuting 是否为1，为1表示nmi嵌套
   1336
   1337         /*
   1338          * Now test if the previous stack was an NMI stack.  This covers
   1339          * the case where we interrupt an outer NMI after it clears
   1340          * "NMI executing" but before IRET.  We need to be careful, though:
   1341          * there is one case in which RSP could point to the NMI stack
   1342          * despite there being no NMI active: naughty userspace controls
   1343          * RSP at the very beginning of the SYSCALL targets.  We can
   1344          * pull a fast one on naughty userspace, though: we program
   1345          * SYSCALL to mask DF, so userspace cannot cause DF to be set
   1346          * if it controls the kernel's RSP.  We set DF before we clear
   1347          * "NMI executing".
   1348          */
   1349         lea     6*8(%rsp), %rdx // ---------------------7
   1350         /* Compare the NMI stack (rdx) with the stack we came from (4*8(%rsp)) */
   1351         cmpq    %rdx, 4*8(%rsp)
   1352         /* If the stack pointer is above the NMI stack, this is a normal NMI */
   1353         ja      first_nmi
   1354
   1355         subq    $EXCEPTION_STKSZ, %rdx
   1356         cmpq    %rdx, 4*8(%rsp)
   1357         /* If it is below the NMI stack, it is a normal NMI */
   1358         jb      first_nmi
   1359
   1360         /* Ah, it is within the NMI stack. */
   1361
   1362         testb   $(X86_EFLAGS_DF >> 8), (3*8 + 1)(%rsp)
   1363         jz      first_nmi       /* RSP was user controlled. */
   1364
   1365         /* This is a nested NMI. */
   1366
   1367 nested_nmi:   // ---------------------8
   1368         /*
   1369          * Modify the "iret" frame to point to repeat_nmi, forcing another
   1370          * iteration of NMI handling.
   1371          */
   1372         subq    $8, %rsp			// 	RSP 指向temp storage for rdx
   1373         leaq    -10*8(%rsp), %rdx	//  rdx 指向NMI-executing 位置
   1374         pushq   $__KERNEL_DS		// 	iret SS
   1375         pushq   %rdx				//	iret RSP
   1376         pushfq						// 	iret RFLAGS
   1377         pushq   $__KERNEL_CS		// 	iret CS
   1378         pushq   $repeat_nmi			// 	iret RIP
   1379
   1380         /* Put stack back */
   1381         addq    $(6*8), %rsp		// 	重新指向temp storage for rdx
   1382
   1383 nested_nmi_out:   // ---------------------9
   1384         popq    %rdx
   1385
   1386         /* We are returning to kernel mode, so this cannot result in a fault. */
   1387         INTERRUPT_RETURN	// original位置现在保存的是nested NMI的 frame，也就是被中断的first nmi的现场，执行iret返回后，继续恢复执行first nmi
   1388
   1389 first_nmi:    // --------------------- 10
   1390         /* Restore rdx. */
   1391         movq    (%rsp), %rdx
   1392
   1393         /* Make room for "NMI executing". */
   1394         pushq   $0
   1395
   1396         /* Leave room for the "iret" frame */
   1397         subq    $(5*8), %rsp				// rsp指向iret frame
   1398
   1399         /* Copy the "original" frame to the "outermost" frame */
   1400         .rept 5
   1401         pushq   11*8(%rsp)
   1402         .endr								// rsp指向 outermost frame
   1403
   ; 1404         /* Everything up to here is safe from nested NMIs */2
   1405
   1406 #ifdef CONFIG_DEBUG_ENTRY
   1407         /*
   1408          * For ease of testing, unmask NMIs right away.  Disabled by
   1409          * default because IRET is very expensive.
   1410          */
   1411         pushq   $0              /* SS */
   1412         pushq   %rsp            /* RSP (minus 8 because of the previous push) */
   1413         addq    $8, (%rsp)      /* Fix up RSP */
   1414         pushfq                  /* RFLAGS */
   1415         pushq   $__KERNEL_CS    /* CS */
   1416         pushq   $1f             /* RIP */
   1417         INTERRUPT_RETURN        /* continues at repeat_nmi below */
   1418 1:
   1419 #endif
   1420	// 一旦出现page fault或者breakpoing等异常，那么异常返回时执行iret，CPU就会重新处于enable NMI的状态，随时可能被新的NMI打断，也就是nested nmi
		// 被中断的NMI执行完毕时也会执行iret指令，就会返回到repeat_nmi，从这里开始执行。
   1421 repeat_nmi:     // ---------------------11
   1422         /*
   1423          * If there was a nested NMI, the first NMI's iret will return
   1424          * here. But NMIs are still enabled and we can take another
   1425          * nested NMI. The nested NMI checks the interrupted RIP to see
   1426          * if it is between repeat_nmi and end_repeat_nmi, and if so
   1427          * it will just return, as we are about to repeat an NMI anyway.
   1428          * This makes it safe to copy to the stack frame that a nested
   1429          * NMI will update.
   1430          *
   1431          * RSP is pointing to "outermost RIP".  gsbase is unknown, but, if
   1432          * we're repeating an NMI, gsbase has the same value that it had on
   1433          * the first iteration.  paranoid_entry will load the kernel
   1434          * gsbase if needed before we call do_nmi.  "NMI executing"
   1435          * is zero.
   1436          */
   1437         movq    $1, 10*8(%rsp)          /* Set "NMI executing". */	// rsp此时指向outermost frame
   1438
   1439         /*
   1440          * Copy the "outermost" frame to the "iret" frame.  NMIs that nest
   1441          * here must not modify the "iret" frame while we're writing to
   1442          * it or it will end up containing garbage.
   1443          */
   1444         addq    $(10*8), %rsp			// 此时rsp指向 NMI executing 位置
   1445         .rept 5
   1446         pushq   -6*8(%rsp)
   1447         .endr
   1448         subq    $(5*8), %rsp			// rsp此时指向outermost frame
   1449 end_repeat_nmi:
  1450
   1451         /*
   1452          * Everything below this point can be preempted by a nested NMI.  // 为什么是从这里开始，CPU有可能响应新的NMI，发生NMI嵌套
   1453          * If this happens, then the inner NMI will change the "iret"
   1454          * frame to point back to repeat_nmi.
   1455          */   
   1456         pushq   $-1                             /* ORIG_RAX: no syscall to restart */
   1457         ALLOC_PT_GPREGS_ON_STACK				// ---------------------12
   1458
   1459         /*
   1460          * Use paranoid_entry to handle SWAPGS, but no need to use paranoid_exit
   1461          * as we should not be calling schedule in NMI context.
   1462          * Even with normal interrupts enabled. An NMI should not be
   1463          * setting NEED_RESCHED or anything that normal interrupts and
   1464          * exceptions might do.
   1465          */
   1466         call    paranoid_entry      
   1467
   1468         /* paranoidentry do_nmi, 0; without TRACE_IRQS_OFF */
   1469         movq    %rsp, %rdi
   1470         movq    $-1, %rsi
   1471         call    do_nmi              // --------------------- 12
   1472
   1473         testl   %ebx, %ebx                      /* swapgs needed? */
   1474         jnz     nmi_restore
   1475 nmi_swapgs:
   1476         SWAPGS_UNSAFE_STACK     // --------------------- 13
   1477 nmi_restore:                  // --------------------- 14
   1478         RESTORE_EXTRA_REGS
   1479         RESTORE_C_REGS
   1480
   1481         /* Point RSP at the "iret" frame. */
   1482         REMOVE_PT_GPREGS_FROM_STACK 6*8									// rsp当前指向 iret frame
   1483
   1484         /*
   1485          * Clear "NMI executing".  Set DF first so that we can easily
   1486          * distinguish the remaining code between here and IRET from
   1487          * the SYSCALL entry and exit paths.  On a native kernel, we
   1488          * could just inspect RIP, but, on paravirt kernels,
   1489          * INTERRUPT_RETURN can translate into a jump into a
   1490          * hypercall page.
   1491          */
   1492         std
   1493         movq    $0, 5*8(%rsp)           /* clear "NMI executing" */		//  rsp当前指向 iret frame
   1494
   1495         /*
   1496          * INTERRUPT_RETURN reads the "iret" frame and exits the NMI
   1497          * stack in a single instruction.  We are returning to kernel
   1498          * mode, so this cannot result in a fault.
   1499          */
   1500         INTERRUPT_RETURN      // --------------------- 14
   1501 END(nmi)
   ```

   1. ENTRY(nmi)
   2. rdx入栈   // rdx即为被中断上下文的RIP，指令地址，入栈后访问的话，即为+8(%rsp)
   3. 如果RIP位于kernel mode，则跳转到5 nmi_from_kernel; 否则nmi from user mode，继续执行
   4. 用户模式nmi处理流程
   5. 如果repeat_nmi =<  interrupted RIP <= end_repeat_nmi，表明当前nmi属于nested_nmi，跳转到nested_nmi_out
       因为被抢占的nmi也刚好正在该代码段执行，正在修改栈上的iret frame。
       则当前nested nmi 直接弹出rdx，不可以修改iret frame，执行iret 返回kernel mode。
       这个nested nmi抢占时机不巧，只能丢弃掉。
   6. 检查NMI executing 标记，为1表示当前nmi为嵌套nmi，跳转到8 nested_nmi;否则继续执行
   7. 检测被中断上下文的栈是否为 nmi stack，如果是跳转到8 nested_nmi；否则跳转到first_nmi
   8. nested_nmi 重新入栈整个iret frame， iret RIP 指向repeat_nmi，这样first_nmi执行iret返回的时候就会跳转到 repeat_nmi 继续处理嵌套nmi
   9. nested_nmi_out        弹出rdx ，执行iret返回
   10. first_nmi:    0入栈，代表NMI executing为0，不是嵌套nmi
       调整rsp，减去40字节的栈空间，留给iret frame，然后把即栈顶位置origianl frame 拷贝到outermost frame
   11. repeat_nmi: 标记NMI executing，表示发生nmi嵌套；然后拷贝outermost frame到 iret frame
       这样的话，等nested_nmi 执行到iret时，就可以从iret frame恢复被first_nmi中断的上下文
       [repeat_nmi, end_repeat_nmi]代码区间是不可重入的，前面第5步骤会做检测，一旦发生重叠，就会直接返回
   12. 栈上分配pt_regs空间，调用paranoid_entry判断是否需要执行swapgs，然后调用do_nmi
       register_nmi_handler注册的handler都挂在
       从这里开始往下 执行的时候，有可能被新的nmi打断
       因为代码执行到这里，就可能会出现触发异常的情况，一旦异常处理完毕返回，就会重新使能nmi，也就有可能发生nmi嵌套
   13. 检测是否需要执行swapgs
   14. 恢复被中断现场，执行iret返回


--------------------------------------------------------------------------------
## qemu gdb单步调试nmi片段

查看IST栈上数据布局
   ```
   (gdb) disassemble nmi
   Dump of assembler code for function nmi:
      0xffffffff814660c0 <+0>:     callq  *0x5dc5aa(%rip)        # 0xffffffff81a42670 <pv_irq_ops+48>  // Paravirtualization虚拟化相关，暂不关注  
      0xffffffff814660c6 <+6>:     push   %rdx						// temp storage for rdx
      0xffffffff814660c7 <+7>:     testb  $0x3,0x10(%rsp)
      0xffffffff814660cc <+12>:    je     0xffffffff81466121 <nmi+97>  // 内核态产生nmi，跳转到 0xffffffff81466121
      0xffffffff814660ce <+14>:    swapgs		// 用户态产生NMI，需要切换gs
      0xffffffff814660d1 <+17>:    cld
      0xffffffff814660d2 <+18>:    mov    %rsp,%rdx
      0xffffffff814660d5 <+21>:    mov    %gs:0x20e04,%rsp
      0xffffffff814660de <+30>:    pushq  0x28(%rdx)
      0xffffffff814660e1 <+33>:    pushq  0x20(%rdx)
      0xffffffff814660e4 <+36>:    pushq  0x18(%rdx)
      0xffffffff814660e7 <+39>:    pushq  0x10(%rdx)
      0xffffffff814660ea <+42>:    pushq  0x8(%rdx)
      0xffffffff814660ed <+45>:    pushq  $0xffffffffffffffff
      0xffffffff814660ef <+47>:    push   %rdi
      0xffffffff814660f0 <+48>:    push   %rsi
      0xffffffff814660f1 <+49>:    pushq  (%rdx)
      0xffffffff814660f3 <+51>:    push   %rcx
      0xffffffff814660f4 <+52>:    push   %rax
      0xffffffff814660f5 <+53>:    push   %r8
      0xffffffff814660f7 <+55>:    push   %r9
      0xffffffff814660f9 <+57>:    push   %r10
      0xffffffff814660fb <+59>:    push   %r11
      0xffffffff814660fd <+61>:    push   %rbx
      0xffffffff814660fe <+62>:    push   %rbp
      0xffffffff814660ff <+63>:    push   %r12
      0xffffffff81466101 <+65>:    push   %r13
      0xffffffff81466103 <+67>:    push   %r14
      0xffffffff81466105 <+69>:    push   %r15
      0xffffffff81466107 <+71>:    mov    %rsp,%rdi
      0xffffffff8146610a <+74>:    mov    $0xffffffffffffffff,%rsi
      0xffffffff81466111 <+81>:    callq  0xffffffff81019fe0 <do_nmi>
      0xffffffff81466116 <+86>:    callq  *0x5dc4f4(%rip)        # 0xffffffff81a42610 <pv_cpu_ops+272>
      0xffffffff8146611c <+92>:    jmpq   0xffffffff81464ab9 <common_interrupt+249>


   // 0x8(%rsp) 为RIP 即被NMI打断的现场的IP地址
      0xffffffff81466121 <+97>:    mov    $0xffffffff814661a2,%rdx		//	movq    $repeat_nmi, %rdx
      0xffffffff81466128 <+104>:   cmp    0x8(%rsp),%rdx				//  比较 rdx > 0x8(%rsp)   0xffffffff814661a2  > 0x8(%rsp) == 0xffffffff81057456
      0xffffffff8146612d <+109>:   ja     0xffffffff8146613d <nmi+125>		// 如果 rdx > 0x8(%rsp)成立 ，表示有可能不是nested nmi, 跳转接着判断其它条件
      0xffffffff8146612f <+111>:   mov    $0xffffffff814661c7,%rdx		//	movq    $end_repeat_nmi, %rdx 0xffffffff81a59080
      0xffffffff81466136 <+118>:   cmp    0x8(%rsp),%rdx				//
      0xffffffff8146613b <+123>:   ja     0xffffffff8146617d <nmi+189>		// ja nested_nmi_out

   //Now test if the previous stack was an NMI stack.
   // NMI stack 包含一个特殊情况，在NMI清除栈上固定位置 NMI executing 标记之后，但是执行iret之前，栈有可能是NMI stack。
   // 就是RSP指向的是nmi stack，但是其实并没有NMI active，因为用户态syscall 会操做rsp
      0xffffffff8146613d <+125>:   cmpl   $0x1,-0x8(%rsp)				// 如果 NMI executing 为1，则表示为nested nmi
      0xffffffff81466142 <+130>:   je     0xffffffff81466165 <nmi+165>		// 跳转到 nested_nmi


   // $rsp + 0x30 即为NMI Stack的首地址；0x20(rsp)上存的是被中断现场的RSP
      0xffffffff81466144 <+132>:   lea    0x30(%rsp),%rdx				// 		0xffff88023fd11fd0 (rsp) + 0x30 == 0xffff88023fd12000 (rdx)，加载立即数
      0xffffffff81466149 <+137>:   cmp    %rdx,0x20(%rsp)				//  判断是否  0x20(%rsp) > nmi stack    0xffff88022027fea8 < 0xffff88023fd12000
      0xffffffff8146614e <+142>:   ja     0xffffffff81466184 <nmi+196>    // 如果0x20(rsp) > nmi stack，则为normal nmi；否则继续往下执行，需要进一步判断
      0xffffffff81466150 <+144>:   sub    $0x1000,%rdx				//  $EXCEPTION_STKSZ == 0x1000
      0xffffffff81466157 <+151>:   cmp    %rdx,0x20(%rsp)			//  判断 0x20(%rsp)0xffff88022029fea8  < NMI-stack 0xffff88023fd11000 成立，跳转到first_nmi
      0xffffffff8146615c <+156>:   jb     0xffffffff81466184 <nmi+196>
      0xffffffff8146615e <+158>:   testb  $0x4,0x19(%rsp)
      0xffffffff81466163 <+163>:   je     0xffffffff81466184 <nmi+196>
   nested_nmi:
      0xffffffff81466165 <+165>:   sub    $0x8,%rsp
      0xffffffff81466169 <+169>:   lea    -0x50(%rsp),%rdx
      0xffffffff8146616e <+174>:   pushq  $0x18
      0xffffffff81466170 <+176>:   push   %rdx
      0xffffffff81466171 <+177>:   pushfq
      0xffffffff81466172 <+178>:   pushq  $0x10
      0xffffffff81466174 <+180>:   pushq  $0xffffffff814661a2
      0xffffffff81466179 <+185>:   add    $0x30,%rsp
   nested_nmi_out:
      0xffffffff8146617d <+189>:   pop    %rdx
      0xffffffff8146617e <+190>:   jmpq   *0x5dc484(%rip)        # 0xffffffff81a42608 <pv_cpu_ops+264>

   // This outermost stack frame is used to fixup the iret stack frame that a nested NMI may change.
   // The iret stack frame modified by any nested NMIs to let the first NMI know that we triggered a second NMI and we should repeat the first NMI handler.
   first_nmi:
      0xffffffff81466184 <+196>:   mov    (%rsp),%rdx
      0xffffffff81466188 <+200>:   pushq  $0x0				// 0 入栈，用于存储NMI executing 标记
      0xffffffff8146618a <+202>:   sub    $0x28,%rsp		// 为 iret frame准备空间
      0xffffffff8146618e <+206>:   pushq  0x58(%rsp)
      0xffffffff81466192 <+210>:   pushq  0x58(%rsp)
      0xffffffff81466196 <+214>:   pushq  0x58(%rsp)
      0xffffffff8146619a <+218>:   pushq  0x58(%rsp)
      0xffffffff8146619e <+222>:   pushq  0x58(%rsp)		//	把orignial frame 拷贝到 outermost frame位置
   repeat_nmi:
      0xffffffff814661a2 <+226>:   movq   $0x1,0x50(%rsp)	// 设置NMI executing标记
      0xffffffff814661ab <+235>:   add    $0x50,%rsp		// rsp 指向 NMI executing标记位置
      0xffffffff814661af <+239>:   pushq  -0x30(%rsp)		// 把outermost frame 拷贝到iret frame，nested nmi此时不应该修改iret frame
      0xffffffff814661b3 <+243>:   pushq  -0x30(%rsp)		//
      0xffffffff814661b7 <+247>:   pushq  -0x30(%rsp)
      0xffffffff814661bb <+251>:   pushq  -0x30(%rsp)
      0xffffffff814661bf <+255>:   pushq  -0x30(%rsp)
      0xffffffff814661c3 <+259>:   sub    $0x28,%rsp		// 调整rsp，指向 outermost RIP位置

   end_repeat_nmi:	 	// 从这里开始往下 执行的时候，有可能被新的nmi打断
   // 入栈-1，作为dummy error code ，类似于处理其它异常那样
   // After this we push dummy error code on the stack as we did it already in the previous exception handlers
      0xffffffff814661c7 <+263>:   pushq  $0xffffffffffffffff		// pushq   $-1      /* ORIG_RAX: no syscall to restart */ 0xffff88023fd11f70
      0xffffffff814661c9 <+265>:   add    $0xffffffffffffff88,%rsp				// ALLOC_PT_GPREGS_ON_STACK 	rsp == 0xffff88023fd11ef0
      0xffffffff814661cd <+269>:   callq  0xffffffff81465ed0 <paranoid_entry>
      0xffffffff814661d2 <+274>:   mov    %rsp,%rdi
      0xffffffff814661d5 <+277>:   mov    $0xffffffffffffffff,%rsi
      0xffffffff814661dc <+284>:   callq  0xffffffff81019fe0 <do_nmi>

   //如果为0，说明前面执行过swapgs，需要顺序执行SWAPGS_UNSAFE_STACK；如果为1，说明没有执行过swapgs，直接跳转到nmi_restore，回复被nmi中断的上下文
      0xffffffff814661e1 <+289>:   test   %ebx,%ebx		//
      0xffffffff814661e3 <+291>:   jne    0xffffffff814661e8 <nmi+296>
      0xffffffff814661e5 <+293>:   swapgs
   nmi_restore:
      0xffffffff814661e8 <+296>:   mov    (%rsp),%r15
      0xffffffff814661ec <+300>:   mov    0x8(%rsp),%r14
      0xffffffff814661f1 <+305>:   mov    0x10(%rsp),%r13
      0xffffffff814661f6 <+310>:   mov    0x18(%rsp),%r12
      0xffffffff814661fb <+315>:   mov    0x20(%rsp),%rbp
      0xffffffff81466200 <+320>:   mov    0x28(%rsp),%rbx
      0xffffffff81466205 <+325>:   mov    0x30(%rsp),%r11
      0xffffffff8146620a <+330>:   mov    0x38(%rsp),%r10
      0xffffffff8146620f <+335>:   mov    0x40(%rsp),%r9
      0xffffffff81466214 <+340>:   mov    0x48(%rsp),%r8
      0xffffffff81466219 <+345>:   mov    0x50(%rsp),%rax
      0xffffffff8146621e <+350>:   mov    0x58(%rsp),%rcx
      0xffffffff81466223 <+355>:   mov    0x60(%rsp),%rdx
      0xffffffff81466228 <+360>:   mov    0x68(%rsp),%rsi
      0xffffffff8146622d <+365>:   mov    0x70(%rsp),%rdi
      0xffffffff81466232 <+370>:   sub    $0xffffffffffffff58,%rsp
      0xffffffff81466239 <+377>:   std
      0xffffffff8146623a <+378>:   movq   $0x0,0x28(%rsp)			// rsp指向 iret frame位置
      0xffffffff81466243 <+387>:   jmpq   *0x5dc3bf(%rip)        # 0xffffffff81a42608 <pv_cpu_ops+264>
   End of assembler dump.
   (gdb)
   (gdb) q


   (gdb) x/8gx 0xffff88023fd11fd0
   0xffff88023fd11fd0:     0xffffffff81a59080      0xffffffff81057456	// rdx	rip
   0xffff88023fd11fe0:     0x0000000000000010      0x0000000000000246	// CS	RFLAGS
   0xffff88023fd11ff0:     0xffff88022027fea8      0x0000000000000018	// Retrun RSP	SS
   0xffff88023fd12000:     0x0000000000000000      0x0000000000000000	// nmi stack start location 0xffff88023fd12000
   (gdb) x/i 0xffffffff81057456      // 被nmi打断的现场，NMI返回后即将执行的指令地址
      0xffffffff81057456 <native_safe_halt+6>:     pop    %rbp

   ┌──Register group: general────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
   │rax            0x0      0                                                         rbx            0xffff880220280000       -131932265906176                           │
   │rcx            0xffffffff81a53ef0       -2119876880                               rdx            0xffffffff81a59080       -2119856000                                │
   │rsi            0xffff88023fd1a8e0       -131931734693664                          rdi            0x46     70                                                         │
   │rbp            0xffff88022027fea8       0xffff88022027fea8                        rsp            0xffff88023fd11f78       0xffff88023fd11f78                         │
   │r8             0x0      0                                                         r9             0x0      0                                                          │
   │r10            0xfffbde9b       4294696603                                        r11            0x246    582                                                        │
   │r12            0x1      1                                                         r13            0xffffffff81ae8278       -2119269768                                │
   │r14            0xffff880220280000       -131932265906176                          r15            0x0      0                                                          │
   │rip            0xffffffff814661a2       0xffffffff814661a2 <nmi+226>              eflags         0x86     [ PF SF ]                                                  │
   │cs             0x10     16                                                        ss             0x18     24                                                         │
   │ds             0x0      0                                                         es             0x0      0                                                          │
   │fs             0x0      0                                                         gs             0x0      0                                                          │
   │                                                                                                                                                                     │
   │                                                                                                                                                                     │
      ┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
      │0xffffffff8146618a <nmi+202>    sub    $0x28,%rsp                                                                                                                 │
      │0xffffffff8146618e <nmi+206>    pushq  0x58(%rsp)                                                                                                                 │
      │0xffffffff81466192 <nmi+210>    pushq  0x58(%rsp)                                                                                                                 │
      │0xffffffff81466196 <nmi+214>    pushq  0x58(%rsp)                                                                                                                 │
      │0xffffffff8146619a <nmi+218>    pushq  0x58(%rsp)                                                                                                                 │
      │0xffffffff8146619e <nmi+222>    pushq  0x58(%rsp)                                                                                                                 │
     >│0xffffffff814661a2 <nmi+226>    movq   $0x1,0x50(%rsp)                                                                                                            │
      │0xffffffff814661ab <nmi+235>    add    $0x50,%rsp                                                                                                                 │
      │0xffffffff814661af <nmi+239>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661b3 <nmi+243>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661b7 <nmi+247>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661bb <nmi+251>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661bf <nmi+255>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661c3 <nmi+259>    sub    $0x28,%rsp                                                                                                                 │
      │0xffffffff814661c7 <nmi+263>    pushq  $0xffffffffffffffff                                                                                                        │
      └──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
   remote Thread 2 In: nmi                                                                                                                   L1437 PC: 0xffffffff814661a2
   0xffff88023fd11fc8:     0x0000000000000000      0xffffffff81a59080
   0xffff88023fd11fd8:     0xffffffff81057456      0x0000000000000010
   0xffff88023fd11fe8:     0x0000000000000246      0xffff88022027fea8
   0xffff88023fd11ff8:     0x0000000000000018      0x0000000000000000
   (gdb) x/20gx 0xffff88023fd11f70
   0xffff88023fd11f70:     0xffffffffffffffff      0xffffffff81057456	// outermost RIP
   0xffff88023fd11f80:     0x0000000000000010      0x0000000000000246	// outermost CS RFLAGS
   0xffff88023fd11f90:     0xffff88022027fea8      0x0000000000000018	// outermost Return RSP	SS
   0xffff88023fd11fa0:     0xffffffff81057456      0x0000000000000010	// iret RIP	CS
   0xffff88023fd11fb0:     0x0000000000000246      0xffff88022027fea8	// iret RFLAGS	Return RSP
   0xffff88023fd11fc0:     0x0000000000000000      0x0000000000000000	// iret SS 		NMI executing room   ??? qmeu中iret ss为0x0，应该是0x0000000000000018，qmeu出错误了？
   0xffff88023fd11fd0:     0xffffffff81a59080      0xffffffff81057456  // rdx  original RIP
   0xffff88023fd11fe0:     0x0000000000000010      0x0000000000000246	// origianl CS	RFLAGS
   0xffff88023fd11ff0:     0xffff88022027fea8      0x0000000000000018 	// original Retrn RSP	SS
   0xffff88023fd12000:     0x0000000000000000      0x0000000000000000  // nmi stack 首地址 0xffff88023fd12000

   pushq  -0x30(%rsp)
   把 outermost frame  拷贝到  iret frame location
   即 0xffff88023fd11f98 ~ 0xffff88023fd11f78 -->  0xffff88023fd11fc0 ~ 0xffff88023fd11fa8


    // Copy the "outermost" frame to the "iret" frame.
      ┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
      │0xffffffff814661ab <nmi+235>    add    $0x50,%rsp      //  rsp == 0xffff88023fd11fc8                                                    │
      │0xffffffff814661af <nmi+239>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661b3 <nmi+243>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661b7 <nmi+247>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661bb <nmi+251>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661bf <nmi+255>    pushq  -0x30(%rsp)                                                                                                                │
     >│0xffffffff814661c3 <nmi+259>    sub    $0x28,%rsp     // 断点走到这里 rsp == 0xffff88023fd11fa0 - 0x28 == 0xffff88023fd11f78      							     │
      │0xffffffff814661c7 <nmi+263>    pushq  $0xffffffffffffffff                                                                                                        │
      │0xffffffff814661c9 <nmi+265>    add    $0xffffffffffffff88,%rsp                                                                                                   │
      │0xffffffff814661cd <nmi+269>    callq  0xffffffff81465ed0 <paranoid_entry>                                                                                        │
      │0xffffffff814661d2 <nmi+274>    mov    %rsp,%rdi                                                                                                                  │
      │0xffffffff814661d5 <nmi+277>    mov    $0xffffffffffffffff,%rsi                                                                                                   │
      │0xffffffff814661dc <nmi+284>    callq  0xffffffff81019fe0 <do_nmi>                                                                                                │
      │0xffffffff814661e1 <nmi+289>    test   %ebx,%ebx                                                                                                                  │
      │0xffffffff814661e3 <nmi+291>    jne    0xffffffff814661e8 <nmi+296>                                                                                               │

   (gdb) x/20gx 0xffff88023fd11f70
   0xffff88023fd11f70:     0xffffffffffffffff      0xffffffff81057456	// outermost RIP
   0xffff88023fd11f80:     0x0000000000000010      0x0000000000000246
   0xffff88023fd11f90:     0xffff88022027fea8      0x0000000000000018
   0xffff88023fd11fa0:     0xffffffff81057456      0x0000000000000010	// iret RIP	CS
   0xffff88023fd11fb0:     0x0000000000000246      0xffff88022027fea8
   0xffff88023fd11fc0:     0x0000000000000018      0x0000000000000001
   0xffff88023fd11fd0:     0xffffffff81a59080      0xffffffff81057456
   0xffff88023fd11fe0:     0x0000000000000010      0x0000000000000246
   0xffff88023fd11ff0:     0xffff88022027fea8      0x0000000000000018
   0xffff88023fd12000:     0x0000000000000000      0x0000000000000000






   ┌──Register group: general────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
   │rax            0x3fd00000       1070596096                                        rbx            0x1      1                                                          │
   │rcx            0xc0000101       3221225729                                        rdx            0xffff8802       4294936578                                         │
   │rsi            0xffff88023fd1a8e0       -131931734693664                          rdi            0xffff88023fd11ef8       -131931734728968                           │
   │rbp            0xffff88022027fea8       0xffff88022027fea8                        rsp            0xffff88023fd11ef8       0xffff88023fd11ef8                         │
   │r8             0x0      0                                                         r9             0x0      0                                                          │
   │r10            0xfffbde9b       4294696603                                        r11            0x246    582                                                        │
   │r12            0x1      1                                                         r13            0xffffffff81ae8278       -2119269768                                │
   │r14            0xffff880220280000       -131932265906176                          r15            0x0      0                                                          │
   │rip            0xffffffff814661d5       0xffffffff814661d5 <nmi+277>              eflags         0x82     [ SF ]                                                     │
   │cs             0x10     16                                                        ss             0x18     24                                                         │
   │ds             0x0      0                                                         es             0x0      0                                                          │
   │fs             0x0      0                                                         gs             0x0      0                                                          │
   │                                                                                                                                                                     │
   │                                                                                                                                                                     │
      ┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
      │0xffffffff814661bb <nmi+251>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661bf <nmi+255>    pushq  -0x30(%rsp)                                                                                                                │
      │0xffffffff814661c3 <nmi+259>    sub    $0x28,%rsp                                                                                                                 │
      │0xffffffff814661c7 <nmi+263>    pushq  $0xffffffffffffffff                                                                                                        │
      │0xffffffff814661c9 <nmi+265>    add    $0xffffffffffffff88,%rsp                                                                                                   │
      │0xffffffff814661cd <nmi+269>    callq  0xffffffff81465ed0 <paranoid_entry>                                                                                        │
      │0xffffffff814661d2 <nmi+274>    mov    %rsp,%rdi                                                                                                                  │
     >│0xffffffff814661d5 <nmi+277>    mov    $0xffffffffffffffff,%rsi                                                                                                   │
      │0xffffffff814661dc <nmi+284>    callq  0xffffffff81019fe0 <do_nmi>                                                                                                │
      │0xffffffff814661e1 <nmi+289>    test   %ebx,%ebx                                                                                                                  │
      │0xffffffff814661e3 <nmi+291>    jne    0xffffffff814661e8 <nmi+296>                                                                                               │
      │0xffffffff814661e5 <nmi+293>    swapgs                                                                                                                            │
      │0xffffffff814661e8 <nmi+296>    mov    (%rsp),%r15                                                                                                                │
      │0xffffffff814661ec <nmi+300>    mov    0x8(%rsp),%r14                                                                                                             │
      │0xffffffff814661f1 <nmi+305>    mov    0x10(%rsp),%r13                                                                                                            │
      └──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
   remote Thread 2 In: nmi                                                                                                                   L1470 PC: 0xffffffff814661d5
   (gdb) fs n
   Focus set to asm window.
   (gdb) disassemble nmi
   (gdb) s
   paranoid_entry () at arch/x86/entry/entry_64.S:1015
   (gdb) n
   (gdb) n
   (gdb) n
   (gdb) n
   (gdb) n
   (gdb) n
   paranoid_entry () at arch/x86/entry/entry_64.S:1025
   (gdb) n
   nmi () at arch/x86/entry/entry_64.S:1469
   (gdb) n

   (gdb) x/36gx $rsp-8  // 调用do_nmi之前，栈里的内容如下，do_nmi第一个参数regs即为rsp  0xffff88023fd11ef8
   0xffff88023fd11ef0:     0xffffffff814661d2      0x0000000000000000
   0xffff88023fd11f00:     0xffff880220280000      0xffffffff81ae8278
   0xffff88023fd11f10:     0x0000000000000001      0xffff88022027fea8
   0xffff88023fd11f20:     0xffff880220280000      0x0000000000000246
   0xffff88023fd11f30:     0x00000000fffbde9b      0x0000000000000000
   0xffff88023fd11f40:     0x0000000000000000      0x0000000000000000
   0xffff88023fd11f50:     0xffffffff81a53ef0      0xffffffff81a59080
   0xffff88023fd11f60:     0xffff88023fd1a8e0      0x0000000000000046
   0xffff88023fd11f70:     0xffffffffffffffff      0xffffffff81057456	// 分配pt_regs空间之前 rsp指向 0xffff88023fd11f70
   0xffff88023fd11f80:     0x0000000000000010      0x0000000000000246	// outermost	CS RFLAGS
   0xffff88023fd11f90:     0xffff88022027fea8      0x0000000000000018	// outermost	return RSP	SS
   0xffff88023fd11fa0:     0xffffffff81057456      0x0000000000000010	// iret 		RIP	CS
   0xffff88023fd11fb0:     0x0000000000000246      0xffff88022027fea8	// iret 		RFLAGS	return RSP
   0xffff88023fd11fc0:     0x0000000000000018      0x0000000000000001	// iret 		SS	NMI executing
   0xffff88023fd11fd0:     0xffffffff81a59080      0xffffffff81057456	// temp for rdx		original RIP
   0xffff88023fd11fe0:     0x0000000000000010      0x0000000000000246	// origianl 	CS	RFLAGS
   0xffff88023fd11ff0:     0xffff88022027fea8      0x0000000000000018	// original		return RSP	SS
   0xffff88023fd12000:     0x0000000000000000      0x0000000000000000

   ```
[参考链接]  
1. <https://lwn.net/Articles/484932/>
2. <https://linux-kernel.vger.kernel.narkive.com/KRnCqHwE/v5-patch-2-6-x86-nmi-create-new-nmi-handler-routines>
