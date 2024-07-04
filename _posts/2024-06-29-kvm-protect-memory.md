---
layout:     post
title:      kvm protect guest memory
subtitle:   kvm保护虚拟机内存
date:       2024-06-29
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - kvm
    - x86
    - memory
    - security
---
# 简介
per-page memory attributes已经合入主线内核，但是最新qemu还没有利用起来。  
heki这个项目没有合入主线内核，但是用到了per-page memory attributes。  
刚好可以用来熟悉、了解和调试虚拟化内存页保护。  

### heki
Hypervisor-Enforced Kernel Integrity 基于kvm强化内核完整性

heki 利用 per-page memory attribute 和 intel mbec 实现对guest内核的保护。

其核心思想是内核自我保护机制应该由一个更具特权的系统组件，即hypervisor，来处理。  
说白了就是guest系统选择不相信自己，或者说在guest自己被hacked情况下依靠host拦截危险。

heki引入了两个hypercall：  
`KVM_HC_LOCK_CR_UPDATE`，允许guest内核锁定一些控制寄存器标志(cr0.wp 和 cr4.smep)。  
`KVM_HC_PROTECT_MEMORY`，使guest内核能够使用 NOWRITE 或 EXEC 属性锁定内存页范围，管理内存权限。  

这两个hypercall都是在guest系统启动阶段下发给host，然后在guest整个生命周期都不可以改动，  
既不能改动控制寄存器保护的标记位，也不能动态更改已经处于保护下的per-page 页面属性。  
即使改动也会因为被host heki拦截而导致失败， guest系统异常。

### mbec
Mode-based execute control 基于模式的执行控制

mbec 是 Intel 处理器虚拟化技术中的一个特性，有助于提高虚拟机的安全性。    
具体来说就是位于处理器控制寄存器中的一个标志位，用于启用或禁用基于EPT的模式执行控制。  
当启用时，处理器将在 EPT 表中查找内存访问权限，以确定虚拟机是否可以执行指定的内存操作。

MBEC提供了更细粒度的执行权限控制，可以保护guest系统的完整性，免受恶意更改。  
通过将扩展页表中的执行启用（X）权限位转换为两个选项来提供额外的细化：针对用户页面的 XU 和针对监管者页面的 XS。  

这一特性的好处在于，hypervisor可以更可靠地验证和强制执行内核代码级别的完整性。  

首先查看host cpu是否支持mbec  
`grep ept_mode_based_exec /proc/cpuinfo`

另外host代码中需要明确添加控制宏`SECONDARY_EXEC_MODE_BASED_EPT_EXEC`。
```
static __init int setup_vmcs_config(struct vmcs_config *vmcs_conf,
				    struct vmx_capability *vmx_cap)
{
	......
	if (_cpu_based_exec_control & CPU_BASED_ACTIVATE_SECONDARY_CONTROLS) {
		min2 = 0;
		opt2 = SECONDARY_EXEC_VIRTUALIZE_APIC_ACCESSES |
			......
			SECONDARY_EXEC_NOTIFY_VM_EXITING |
			SECONDARY_EXEC_MODE_BASED_EPT_EXEC;  // 另外还要添加控制宏，vmcs使能mbec
		if (cpu_has_sgx())
			opt2 |= SECONDARY_EXEC_ENCLS_EXITING;
		if (adjust_vmx_controls(min2, opt2,
					MSR_IA32_VMX_PROCBASED_CTLS2,
					&_cpu_based_2nd_exec_control) < 0)
			return -EIO;
	}
	......
	return 0;
}
```

### per-page memory attributes
`KVM_SET_MEMORY_ATTRIBUTES` 允许用户空间为一段guest物理内存设置内存属性。

其实现使用一个 xarray 来内部存储每页属性。  
使用 0-2 位来表示 RWX 属性/保护。使用第 3 位作为 PRIVATE 属性，KVM 可以在未来使用。

提供架构钩子，在通用代码设置新属性之前和之后处理属性更改，  
使用 "pre" 钩子来清除所有相关映射，`kvm_pre_set_memory_attributes`    
使用 "post" 钩子来跟踪是否可以使用大页映射该范围，`kvm_arch_post_set_memory_attributes`

---------------------------------------------------------------------------------------------
由于需要host和guest协同完成对guest内存页的保护，下面分开叙述。

## guest protect memory hypercall

guest主要收集直接映射区域内存页面权限属性，收集完之后就调用hypercall，通知到host。

收集每页属性时用到两个结构体，struct heki_page_list和struct heki_pages。    
页开头位置存储`struct heki_page_list` 结构体信息，紧接着数组形式存放多个 `struct heki_pages`，  
因为页面数量较大，可能分配多个page存储`struct heki_pages`。

```
start_kernel
  heki_early_init
    heki_arch_early_init
      heki_map(kernel_va, direct_map_va);  // 非直接映射区域只统计权限数值，并不需要下发给host。   
      heki_map(direct_map_end, kernel_end);      
  kernel_init
    heki_late_init
      heki_arch_late_init
        heki_protect(direct_map_va, direct_map_end);  // 关注该流程
```


guest 启动初始化阶段先收集直接映射区域范围内的所有页面权限属性。  
遍历页表的时候，只有建立好了映射，即存在对应的页表条目，才会收集该page的页面权限属性。  

针对直接映射区域，收集时分配一个(或者多个)page，page入口处存储结构体`struct heki_page_list`，  
紧接着存放多个结构体`struct heki_pages`，用于存放每个页面的权限属性值。

具体是在`heki_protect`中完成的。代码流程如下。
```
heki_protect
  heki_func
  	heki_walk(va, end, heki_callback, args);  
  		heki_callback
        heki_add_pa   // 大量内存页的权限属性需要多个page页面才能记录下来，每新增一页记录集合，即添加到链表中
          	hpage->permissions = permissions;
  heki_apply_permissions(args);  // 下发内存页属性，告知host。
	hypervisor->protect_memory(list_pa); // kvm_protect_memory
		kvm_hypercall1(KVM_HC_PROTECT_MEMORY, pa);
```

guest 通过protect memory hypercall陷入host处理流程。如下是调用栈:
```
[    6.392258] CPU: 2 PID: 1 Comm: swapper/0 Tainted: G                 N 6.6.0-rc5-ge95273a46ce1-dirty #46
[    6.394131] Hardware name: QEMU Standard PC (i440FX + PIIX, 1996), BIOS rel-1.16.1-0-g3208b098f51a-prebuilt.qemu.org 04/01/2014
[    6.396369] Call Trace:
[    6.396890]  <TASK>
[    6.397337]  dump_stack_lvl+0x37/0x50
[    6.398093]  kvm_protect_memory+0x22/0x60
[    6.398899]  heki_apply_permissions+0x2d/0x70
[    6.399776]  ? __pfx_kernel_init+0x10/0x10
[    6.400596]  heki_func.part.0+0x62/0x80
[    6.401366]  heki_protect+0x82/0xb0
[    6.402076]  heki_arch_late_init+0x1c/0x30
[    6.402902]  heki_late_init+0x37/0x50
[    6.403639]  kernel_init+0x54/0x1c0
[    6.404348]  ret_from_fork+0x31/0x50
[    6.405075]  ? __pfx_kernel_init+0x10/0x10
[    6.405895]  ret_from_fork_asm+0x1b/0x30
[    6.406678]  </TASK>

```
## host handle hypercall

host 会从guest的内存空间读取 struct heki_page_list所有内容，然后清EPT页表，保存内存页属性值
```
heki_protect_memory
  kvm_read_guest(kvm, list_pa, list, sizeof(*list)); // 获取 struct heki_page_list
  kvm_read_guest(kvm, list_pa, pages, size); // 获取 struct heki_pages 数组
  kvm_permissions_set((kvm, gfn_start, gfn_end, permissions);
```
```
kvm_permissions_set
	kvm_vm_set_mem_attributes
		kvm_handle_gfn_range(kvm, &pre_set_range);  // pre
			kvm_pre_set_memory_attributes
				kvm_mmu_invalidate_range_add
				kvm_arch_pre_set_memory_attributes
					kvm_unmap_gfn_range(kvm, range);    
						kvm_tdp_mmu_zap_gfn_range    // 解除映射 spte清零
		xa_err(xa_store(&kvm->mem_attr_array, i, entry, GFP_KERNEL_ACCOUNT));  // 页面属性保存到 kvm xarray
		kvm_handle_gfn_range(kvm, &post_set_range);  // post
			kvm_arch_post_set_memory_attributes
```

`kvm_unmap_gfn_range`中解除映射，还包括rmap。
```
1634 bool kvm_unmap_gfn_range(struct kvm *kvm, struct kvm_gfn_range *range)
1635 {
1636         bool flush = false;
1637         if (kvm_memslots_have_rmaps(kvm))
1638                 flush = kvm_handle_gfn_range(kvm, range, kvm_zap_rmap);
1639
1640         if (kvm->arch.tdp_mmu_enabled)
1642                 kvm_tdp_mmu_zap_gfn_range(kvm, range->start, range->end);   // 这里清零spte
1644
1645         if (kvm_x86_ops.set_apic_access_page_addr &&
1646             range->slot->id == APIC_ACCESS_PAGE_PRIVATE_MEMSLOT)
1647                 kvm_make_all_cpus_request(kvm, KVM_REQ_APIC_PAGE_RELOAD);
1648
1649         return flush;
1650 }
```

解除映射之后，还要通知其它cpu刷新tlb
```
kvm_handle_gfn_range
	range->handler(kvm, &gfn_range);
	kvm_flush_remote_tlbs(kvm); //
```

清除给定范围内ept页表项之后，等到触发host ept violation(tdp page fault)事件，  
再通过`kvm_permissions_get`获取每个页面权限属性后设置到ept页表中
```
vcpu_enter_guest
	kvm_x86_ops.handle_exit(vcpu, exit_fastpath);  // vmx_handle_exit
		__vmx_handle_exit
			handle_ept_violation
```
```
handle_ept_violation
	kvm_mmu_page_fault
		kvm_mmu_do_page_fault
			kvm_tdp_page_fault(vcpu, cr2_or_gpa, err, prefault);
				direct_page_fault
					kvm_tdp_mmu_map
						tdp_mmu_map_handle_target_level
							make_spte
								kvm_permissions_get(vcpu->kvm, gfn);
							if (new_spte != iter->old_spte)
								tdp_mmu_set_spte
									__tdp_mmu_set_spte
										WRITE_ONCE(*iter->sptep, new_spte);
```

host 响应hypercall的调用栈如下:
```
qemu-system-x86-10211   [004] .N..   276.646160: <stack trace>
=> __ftrace_trace_stack
=> kvm_permissions_set
=> heki_protect_memory
=> kvm_emulate_hypercall   // guest protect memory hypercall
=> vmx_handle_exit
=> vcpu_enter_guest
=> vcpu_run
=> kvm_arch_vcpu_ioctl_run
=> kvm_vcpu_ioctl
=> __se_sys_ioctl
=> do_syscall_64
=> entry_SYSCALL_64_after_hwframe
```

# trigger ept violation
`handle_ept_violation` 从 `exit_qualification`中提取出`error_code`，  
交给后续流程做相应处理。  
```
#define PFERR_PRESENT_BIT 0
#define PFERR_WRITE_BIT 1
#define PFERR_USER_BIT 2
#define PFERR_RSVD_BIT 3
#define PFERR_FETCH_BIT 4
```

`mem_attr_fault` 会获取guest 产生page fault的原因，   
写权限违规会被识别到，host 构造并注入page fault，guest就会触发异常。  
```
handle_ept_violation
	kvm_mmu_page_fault
		kvm_mmu_do_page_fault
			kvm_tdp_page_fault(vcpu, cr2_or_gpa, err, prefault);
				direct_page_fault
					mem_attr_fault	
```

`mem_attr_fault`识别并拦截guest违规操作。  
```
static bool mem_attr_fault(struct kvm_vcpu *vcpu, struct kvm_page_fault *fault)
{
	unsigned long perm;
	bool noexec, nowrite;

	if (unlikely(fault->rsvd))
		return false;

	if (!fault->present)
		return false;

	perm = kvm_permissions_get(vcpu->kvm, fault->gfn);
	noexec = !(perm & MEM_ATTR_EXEC);
	nowrite = !(perm & MEM_ATTR_WRITE);

	if (fault->exec && noexec) {
		struct x86_exception exception = {
			.vector = PF_VECTOR,
			.error_code_valid = true,
			.error_code = fault->error_code,
			.nested_page_fault = false,
			/*
			 * TODO: This kind of kernel page fault needs to be
			 * handled by the guest, which is not currently the
			 * case, making it try again and again.
			 *
			 * You may want to test with cr2_or_gva to see the page
			 * fault caught by the guest kernel (thinking it is a
			 * user space fault).
			 */
			.address = static_call(kvm_x86_fault_gva)(vcpu),
			.async_page_fault = false,
		};

		pr_warn_ratelimited(
			"heki: Creating fetch #PF at 0x%016llx GFN=%llx\n",
			exception.address, fault->gfn);
		kvm_inject_page_fault(vcpu, &exception);
		return true;
	}

	if (fault->write && nowrite) {
		struct x86_exception exception = {
			.vector = PF_VECTOR,
			.error_code_valid = true,
			.error_code = fault->error_code,
			.nested_page_fault = false,
			/*
			 * TODO: This kind of kernel page fault needs to be
			 * handled by the guest, which is not currently the
			 * case, making it try again and again.
			 *
			 * You may want to test with cr2_or_gva to see the page
			 * fault caught by the guest kernel (thinking it is a
			 * user space fault).
			 */
			.address = static_call(kvm_x86_fault_gva)(vcpu),
			.async_page_fault = false,
		};

		pr_warn_ratelimited(
			"heki: Creating write #PF at 0x%016llx GFN=%llx\n",
			exception.address, fault->gfn);
		kvm_inject_page_fault(vcpu, &exception);
		return true;
	}
	return false;
}
```

### write read-only page test

给虚拟机传递内核参数heki_test=3，进行写只读页的测试。  
```
qemu-system-x86_64 -m 4096m -smp 8 \
        -cpu host,smep=on \
        -kernel arch/x86/boot/bzImage \
        -append "rdinit=/bin/sh console=ttyS0 kgdboc=ttyS0,15200 heki_test=3" \
        -nographic --enable-kvm -initrd rootfs.cpio.gz
```

host拦截并注入page fault， guest 触发 page fault打印如下  
`error_code`字段值为0x2，bit 1 置位，表示写数据导致的ept violation。  
```
<6>[    5.142523][    T1] heki-guest: Trying memory write
<1>[    8.681539][    T1] BUG: kernel NULL pointer dereference, address: 000000000000010e
<1>[    8.686793][    T1] #PF: supervisor write access in kernel mode
<1>[    8.688368][    T1] #PF: error_code(0x0002) - not-present page
<6>[    8.689909][    T1] PGD 0 P4D 0
<4>[    8.690797][    T1] Oops: 0002 [#1] SMP PTI
<4>[    8.691928][    T1] CPU: 3 PID: 1 Comm: swapper/0 Not tainted 5.10.0-136.12.0.86.c.heki.x86_64 #22
<4>[    8.694297][    T1] Hardware name: QEMU Standard PC (i440FX + PIIX, 1996), BIOS rel-1.16.1-0-g3208b098f51a-prebuilt.qemu.org 04/01/2014
<4>[    8.697529][    T1] RIP: 0010:heki_test_write_to_rodata.cold+0x81/0xb8
<4>[    8.704366][    T1] RSP: 0000:ffffc90000013f20 EFLAGS: 00010246
<4>[    8.705941][    T1] RAX: 000000000000001f RBX: ffffffff82b3aec0 RCX: ffffffff835305e8
<4>[    8.708010][    T1] RDX: 0000000000000000 RSI: 0000000000000000 RDI: ffffffff83f8fe58
<4>[    8.710076][    T1] RBP: ffffffff82b3a000 R08: 0000000000000000 R09: ffffc90000013d68
<4>[    8.712148][    T1] R10: ffffc90000013d60 R11: ffffffff835f0628 R12: 0000000000000000
<4>[    8.714224][    T1] R13: 0000000000000000 R14: 0000000000000000 R15: 0000000000000000
<4>[    8.716296][    T1] FS:  0000000000000000(0000) GS:ffff88813bd80000(0000) knlGS:0000000000000000
<4>[    8.718612][    T1] CS:  0010 DS: 0000 ES: 0000 CR0: 0000000080050033
<4>[    8.720313][    T1] CR2: 000000000000010e CR3: 000000000320a001 CR4: 0000000000770ee0
<4>[    8.722376][    T1] DR0: 0000000000000000 DR1: 0000000000000000 DR2: 0000000000000000
<4>[    8.724443][    T1] DR3: 0000000000000000 DR6: 00000000fffe0ff0 DR7: 0000000000000400
<4>[    8.726508][    T1] PKRU: 55555554
<4>[    8.727422][    T1] Call Trace:
<4>[    8.728352][    T1]  ? rest_init+0xb4/0xb4
<4>[    8.729451][    T1]  kernel_init+0x49/0x11c
<4>[    8.730574][    T1]  ret_from_fork+0x1f/0x30
<4>[    8.731716][    T1] Modules linked in:
```

### exec non-exec page test
给虚拟机传递内核参数heki_test=4，让guest cpu执行不可执行权限页面上的指令数据。  
```
qemu-system-x86_64 -m 4096m -smp 8 \
        -cpu host,smep=on \
        -kernel arch/x86/boot/bzImage \
        -append "rdinit=/bin/sh console=ttyS0 kgdboc=ttyS0,15200 heki_test=4" \
        -nographic --enable-kvm -initrd rootfs.cpio.gz
```

host拦截并注入page fault， guest 触发 page fault打印如下  
`error_code`字段值为0x11，bit 0和bit 4置位，表示读指令数据导致的ept violation。  
```
<4>[    4.713765] heki-guest: Failed to set memory permission
<4>[    4.714976]     # heki_test_exec: Trying to execute data (ROP) in (initially) non-executable memory
<4>[    4.718756] CPU: 5 PID: 96 Comm: kunit_try_catch Tainted: G                 N 6.6.0-rc5-ge95273a46ce1-dirty #189
<4>[    4.720818] Hardware name: QEMU Standard PC (i440FX + PIIX, 1996), BIOS rel-1.16.1-0-g3208b098f51a-prebuilt.qemu.org 04/01/2014
<1>[    4.749726] BUG: kernel NULL pointer dereference, address: 0000000000000001
<1>[    4.751133] #PF: supervisor instruction fetch in kernel mode
<1>[    4.752292] #PF: error_code(0x0011) - permissions violation
<6>[    4.753423] PGD 0 P4D 0
<4>[    4.753955] Oops: 0011 [#1] PREEMPT SMP PTI
<4>[    4.754814] CPU: 5 PID: 96 Comm: kunit_try_catch Tainted: G                 N 6.6.0-rc5-ge95273a46ce1-dirty #189
<4>[    4.756857] Hardware name: QEMU Standard PC (i440FX + PIIX, 1996), BIOS rel-1.16.1-0-g3208b098f51a-prebuilt.qemu.org 04/01/2014
<4>[    4.759152] RIP: 0010:heki_test_exec_data+0x0/0xf
<4>[    4.763843] RSP: 0000:ffffc9000038feb0 EFLAGS: 00010282
<4>[    4.764908] RAX: 0000000000000000 RBX: ffffc90000013a40 RCX: 00000000ffffdfff
<4>[    4.766351] RDX: ffffffff824421a2 RSI: ffffffff824b5190 RDI: 0000000000000003
<4>[    4.767784] RBP: ffffc90000013a28 R08: ffffffff82743208 R09: 0000000000009ffb
<4>[    4.769230] R10: 00000000000001ad R11: ffffffff82713220 R12: ffffffff82107000
<4>[    4.770669] R13: ffff888106f5c100 R14: ffffffff814badf0 R15: ffffc90000013a40
<4>[    4.772126] FS:  0000000000000000(0000) GS:ffff88813bd40000(0000) knlGS:0000000000000000
<4>[    4.773754] CS:  0010 DS: 0000 ES: 0000 CR0: 0000000080050033
<4>[    4.774914] CR2: 0000000000000001 CR3: 000000000262e001 CR4: 0000000000770ee0
<4>[    4.776355] DR0: 0000000000000000 DR1: 0000000000000000 DR2: 0000000000000000
<4>[    4.777791] DR3: 0000000000000000 DR6: 00000000fffe0ff0 DR7: 0000000000000400
<4>[    4.779234] PKRU: 55555554
<4>[    4.779793] Call Trace:
<4>[    4.780309]  <TASK>
<4>[    4.780755]  ? __die+0x24/0x70
<4>[    4.781397]  ? page_fault_oops+0x17b/0x450
<4>[    4.782237]  ? exc_page_fault+0x7d/0x170
<4>[    4.783038]  ? asm_exc_page_fault+0x26/0x30
<4>[    4.783894]  ? __pfx_kunit_generic_run_threadfn_adapter+0x10/0x10
<4>[    4.785140]  ? heki_test_exec+0xcf/0x1a0
<4>[    4.785940]  ? __pfx_kunit_generic_run_threadfn_adapter+0x10/0x10
<4>[    4.787177]  ? kunit_generic_run_threadfn_adapter+0x17/0x30
<4>[    4.788306]  ? kthread+0xe3/0x120
<4>[    4.788990]  ? __pfx_kthread+0x10/0x10
<4>[    4.789764]  ? ret_from_fork+0x31/0x50
<4>[    4.790538]  ? __pfx_kthread+0x10/0x10
<4>[    4.791313]  ? ret_from_fork_asm+0x1b/0x30
<4>[    4.792153]  </TASK>
<4>[    4.792612] Modules linked in:
```

### tracer collision
heki 和 tracer 等跟踪特性冲突。前者不允许修改.text，后者必须修改.text才能生效。

guest启动 mark kernel readonly 之后，由于.text文本段所在的内存区域被heki标记为immutable，    
也就是说整个系统运行期间都不可以更改，所以 tracer 跟踪器（kprobe/ftrace/ebpf等）不可用。  

x86修改内核文本段的总入口是 `text_poke` 函数。heki在这里加了钩子。   
临时修改指令所在内存页权限属性，并通过hypercall通知到host。    

```
__text_poke
	heki_text_poke_start(pages, cross_page_boundary ? 2 : 1, pgprot);
		heki_text_poke_common
			heki_apply_permissions
	unc((u8 *)poking_addr + offset_in_page(addr), src, len);  // 插入指令
	heki_text_poke_end(pages, cross_page_boundary ? 2 : 1, pgprot);
		heki_text_poke_common
			heki_apply_permissions
```

host响应流程会检测是否允许修改页面的权限属性。  
```
heki_protect_memory
	kvm_permissions_set
		if (kvm_range_has_memory_attributes(kvm, gfn_start, gfn_end,
						KVM_MEMORY_ATTRIBUTE_HEKI_IMMUTABLE, false)) 
			return -EPERM;
```

为了让tracer生效，给__text_poke流程中的hypercall开个后门，跳过检查，修改如下   
```
diff --git a/arch/x86/kvm/x86.c b/arch/x86/kvm/x86.c
index 44f94b75f..6e9f080ff 100644
--- a/arch/x86/kvm/x86.c
+++ b/arch/x86/kvm/x86.c
@@ -10088,7 +10088,7 @@ static int heki_protect_memory(struct kvm *const kvm, gpa_t list_pa)
 				(permissions & MEM_ATTR_EXEC) ? "x" : "_");
 
 			err = kvm_permissions_set(kvm, gfn_start, gfn_end,
-						  permissions);
+						  permissions, head->text_poke);
 			if (err) {
 				pr_warn("heki: Failed to set permissions\n");
 				goto unlock;
diff --git a/arch/x86/mm/heki.c b/arch/x86/mm/heki.c
index 6c3fa9def..8798105d9 100644
--- a/arch/x86/mm/heki.c
+++ b/arch/x86/mm/heki.c
@@ -119,7 +119,7 @@ static void heki_text_poke_common(struct page **pages, int npages,
 	}
 
 	if (args.head)
-		heki_apply_permissions(&args);
+		heki_apply_permissions(&args, 1);
 
 	mutex_unlock(&heki_lock);
 }
diff --git a/include/linux/heki.h b/include/linux/heki.h
index 9e2cf0051..b281dd428 100644
--- a/include/linux/heki.h
+++ b/include/linux/heki.h
@@ -54,6 +54,7 @@ struct heki_page_list {
 	struct heki_page_list *next;
 	gpa_t next_pa;
 	unsigned long npages;
+	bool text_poke;
 	struct heki_pages pages[];
 };
 
@@ -148,7 +149,7 @@ void heki_callback(struct heki_args *args);
 void heki_protect(unsigned long va, unsigned long end);
 void heki_add_pa(struct heki_args *args, phys_addr_t pa,
 		 unsigned long permissions);
-void heki_apply_permissions(struct heki_args *args);
+void heki_apply_permissions(struct heki_args *args, bool text_poke);
 void heki_run_test(void);
 
 /* Arch-specific functions. */
diff --git a/include/linux/kvm_mem_attr.h b/include/linux/kvm_mem_attr.h
index 0a755025e..7a9b533dd 100644
--- a/include/linux/kvm_mem_attr.h
+++ b/include/linux/kvm_mem_attr.h
@@ -26,7 +26,7 @@
 /* clang-format on */
 
 int kvm_permissions_set(struct kvm *kvm, gfn_t gfn_start, gfn_t gfn_end,
-			unsigned long heki_attr);
+			unsigned long heki_attr, bool text_poke);
 unsigned long kvm_permissions_get(struct kvm *kvm, gfn_t gfn);
 
 #endif /* __KVM_MEM_ATTR_H__ */
diff --git a/virt/heki/counters.c b/virt/heki/counters.c
index 302113bee..7629c7d49 100644
--- a/virt/heki/counters.c
+++ b/virt/heki/counters.c
@@ -185,7 +185,7 @@ static void heki_func(unsigned long va, unsigned long end,
 	heki_walk(va, end, heki_callback, args);
 
 	if (args->head)
-		heki_apply_permissions(args);
+		heki_apply_permissions(args, 0);
 
 	mutex_unlock(&heki_lock);
 }
diff --git a/virt/heki/main.c b/virt/heki/main.c
index ce9984231..f91aefbec 100644
--- a/virt/heki/main.c
+++ b/virt/heki/main.c
@@ -116,7 +116,7 @@ void heki_add_pa(struct heki_args *args, phys_addr_t pa,
 	goto again;
 }
 
-void heki_apply_permissions(struct heki_args *args)
+void heki_apply_permissions(struct heki_args *args, bool text_poke)
 {
 	struct heki_hypervisor *hypervisor = heki.hypervisor;
 	struct heki_page_list *list = args->head;
@@ -129,6 +129,7 @@ void heki_apply_permissions(struct heki_args *args)
 
 	/* The very last one must be included. */
 	list->npages++;
+	list->text_poke = text_poke;
 
 	/* Protect guest memory in the host page table. */
 	ret = hypervisor->protect_memory(list_pa);
diff --git a/virt/lib/kvm_permissions.c b/virt/lib/kvm_permissions.c
index 9f4e8027d..4c44b9748 100644
--- a/virt/lib/kvm_permissions.c
+++ b/virt/lib/kvm_permissions.c
@@ -80,7 +80,7 @@ unsigned long kvm_permissions_get(struct kvm *kvm, gfn_t gfn)
 EXPORT_SYMBOL_GPL(kvm_permissions_get);
 
 int kvm_permissions_set(struct kvm *kvm, gfn_t gfn_start, gfn_t gfn_end,
-			unsigned long heki_attr)
+			unsigned long heki_attr, bool text_poke)
 {
 	if ((heki_attr | MEM_ATTR_PROT) != MEM_ATTR_PROT)
 		return -EINVAL;
@@ -88,7 +88,7 @@ int kvm_permissions_set(struct kvm *kvm, gfn_t gfn_start, gfn_t gfn_end,
 	if (gfn_end <= gfn_start)
 		return -EINVAL;
 
-	if (kvm_range_has_memory_attributes(kvm, gfn_start, gfn_end,
+	if (!text_poke && kvm_range_has_memory_attributes(kvm, gfn_start, gfn_end,
 					    KVM_MEMORY_ATTRIBUTE_HEKI_IMMUTABLE,
 					    false)) {
 		pr_warn_ratelimited(
```


# 参考
[linux-5.10](https://elixir.bootlin.com/linux/v5.10/source)  
[heki github](https://github.com/heki-linux)  
[heki patches](https://lore.kernel.org/lkml/20231113022326.24388-1-mic@digikod.net/)  
[per-page memory attributes](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/commit/virt/kvm/kvm_main.c?id=5a475554db1e476a14216e742ea2bdb77362d5d5)  
