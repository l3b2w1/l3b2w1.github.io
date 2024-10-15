---
layout:     post
title:      kvm gpa to hva
subtitle:   内存虚拟化之地址转换
date:       2024-10-15
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - kvm
    - memory
    - x86_64
---
### 映射关系
GVA -> GPA 映射关系 保存在 Guest OS 页表中。  
GPA -> HVA 映射关系 保存在 kvm memslot 数组中。  
GPA -> HPA 映射关系 保存在 kvm ept 页表中(或者影子页表)。  
HVA -> HPA 映射关系 保存在 Host OS 页表中。  

### 相关代码
qemu 进程会准备好可用虚拟内存空间，类似于物理机的内存条  
因地址空间不连续的原因，会注册多个 memslot 到 kvm 模块，相关字段解释如下
```
struct kvm_memory_slot {
	struct hlist_node id_node[2];
	struct interval_tree_node hva_node[2];
	struct rb_node gfn_node[2];
	gfn_t base_gfn; 	// guest物理页帧号
	unsigned long npages;	// guest 物理页面个数
	unsigned long *dirty_bitmap;
	struct kvm_arch_memory_slot arch;
	unsigned long userspace_addr; // hva 用户空间虚拟地址, qemu 进程分配到的虚拟内存空间首地址
	u32 flags;
	short id;  	 // slot id;  低16位
	u16 as_id;   // address space id 高16位
};
```

gfn 转换为 hva
```
static inline unsigned long
__gfn_to_hva_memslot(const struct kvm_memory_slot *slot, gfn_t gfn)
{
	/*
	 * The index was checked originally in search_memslots.  To avoid
	 * that a malicious guest builds a Spectre gadget out of e.g. page
	 * table walks, do not let the processor speculate loads outside
	 * the guest's registered memslots.
	 */
	unsigned long offset = gfn - slot->base_gfn;  //gfn相对guest起始物理页帧号base_gfn的偏移页面个数
	offset = array_index_nospec(offset, slot->npages);  // 越界检查
	return slot->userspace_addr + offset * PAGE_SIZE;  // qemu进程用户态虚拟地址空间首地址就是 userspace_addr 再加上页偏移就是hva
}
```

下面测试代码用的是内核直接导出的函数 `gfn_to_hva`  
`gfn_to_hva ->   gfn_to_hva_many -> __gfn_to_hva_memslot`

### 地址转换
x86_64 只用了48位地址空间，测试用系统采用5级页表配置，所以PGD和P4D重叠，二者页表项内容一致。  
```
Guest: PGD 80000001050e4067 P4D 80000001050e4067
Host : PGD 8000000220eaf067 P4D 8000000220eaf067
```

从下面测试中可以看到guest上的 4K 页，host上却属于 2M 大页。  

**Guest**  
由`libc.so.6`的一段地址空间首地址`7f34ef90f000`，即 GVA，转换得到 GPA `0x13b483000`
```
# ps
	..0....
	201 root     /sbin/klogd -n
	213 root     /usr/sbin/crond -f
	219 root     -sh
	220 root     /sbin/getty -L tty1 0 vt100
	222 root     ps
# cat /proc/201/maps
55efe7882000-55efe788e000 r--p 00000000 00:02 458                        /bin/busybox
55efe788e000-55efe7914000 r-xp 0000c000 00:02 458                        /bin/busybox
55efe7914000-55efe793b000 r--p 00092000 00:02 458                        /bin/busybox
55efe793b000-55efe793e000 r--p 000b9000 00:02 458                        /bin/busybox
55efe793e000-55efe793f000 rw-p 000bc000 00:02 458                        /bin/busybox
55efe7b50000-55efe7b71000 rw-p 00000000 00:00 0                          [heap]
7f34ef90c000-7f34ef90f000 rw-p 00000000 00:00 0
7f34ef90f000-7f34ef937000 r--p 00000000 00:02 74                         /lib/libc.so.6
```
`# insmod /v2p.ko pid=201 vaddr=0x7f34ef90f000`
```
[ 1727.099719][  T233] PGD 80000001050e4067 P4D 80000001050e4067 PUD 1050e7067 PMD 1016a0067 PTE 800000013b483025
[ 1727.102810][  T233] Physical address for pid 201, virtual address 0x7f34ef90f000: 0x13b483000
```


**HOST**  
host上根据 GPA `0x13b483000` 和 qemu 进程 pid `304786`，转换得到 HVA `0x7fec17283000`

`# insmod ./gkvm.ko pid=304786 gpa=0x13b483000`
```
# dmesg
[94762.874954] base pfn 0x 100000, npages  262144, hva 0x7febdbe00000 id    1 as_id 0
[94762.875733] base pfn 0x  fffc0, npages      64, hva 0x7fec20600000 id    2 as_id 0
[94762.876478] base pfn 0x  fee00, npages       1, hva 0x7fec22b91000 id  510 as_id 0
[94762.877181] base pfn 0x  fd000, npages    4096, hva 0x7feb0ae00000 id    4 as_id 0
[94762.877896] base pfn 0x    100, npages  786176, hva 0x7feb1bf00000 id    9 as_id 0
[94762.878609] base pfn 0x     f0, npages      16, hva 0x7feb1bef0000 id    8 as_id 0
[94762.879313] base pfn 0x     e8, npages       8, hva 0x7feb1bee8000 id    7 as_id 0
[94762.880022] base pfn 0x     ce, npages      26, hva 0x7feb1bece000 id    6 as_id 0
[94762.880730] base pfn 0x     cb, npages       3, hva 0x7feb1becb000 id    5 as_id 0
[94762.881441] base pfn 0x     c0, npages      11, hva 0x7feb1bec0000 id    3 as_id 0
[94762.882140] base pfn 0x      0, npages     160, hva 0x7feb1be00000 id    0 as_id 0
[94762.882849] PGD 8000000220eaf067 P4D 8000000220eaf067 PUD 2e31c3067 PMD 8000000449a008e7
[94762.883560] gpa 0x13b483000, hva 0x7fec17283000, hpa 0x449a83000
```

### virt_to_phys 模块
```
#include <linux/module.h>
#include <linux/init.h>
#include <linux/mm.h>
#include <linux/kvm_host.h>
#include <linux/pid.h>
#include <linux/mm_types.h>
#include <linux/uaccess.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/sched.h>
#include <linux/uaccess.h>
#include <linux/huge_mm.h>

static int pid;
module_param(pid, int, 0);
MODULE_PARM_DESC(pid, "Process ID");

static unsigned long vaddr;
module_param(vaddr, ulong, 0);
MODULE_PARM_DESC(vaddr, "User virtual address");

static int bad_address(void *p)
{
	unsigned long dummy;

	return get_kernel_nofault(dummy, (unsigned long *)p);
}

static unsigned long v2p(int pid, unsigned long vaddr)
{
	struct task_struct *task;
	struct mm_struct *mm;
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;
	struct page *page;
	unsigned long paddr = 0;

	rcu_read_lock();
	task = pid_task(find_vpid(pid), PIDTYPE_PID);
	if (!task) {
		pr_err("No such process with pid: %d\n", pid);
		rcu_read_unlock();
		return 0;
	}

	mm = task->mm;
	if (!mm) {
		pr_err("Process %d does not have a valid memory descriptor\n", pid);
		rcu_read_unlock();
		return 0;
	}

	down_read(&mm->mmap_lock);

	pgd = pgd_offset(mm, vaddr);
	if (bad_address(pgd))
		goto bad;

	pr_info("PGD %lx ", pgd_val(*pgd));
	if (!pgd_present(*pgd))
		goto none;

	p4d = p4d_offset(pgd, vaddr);
	if (bad_address(p4d))
		goto bad;

	pr_cont("P4D %lx ", p4d_val(*p4d));
	if (!p4d_present(*p4d))
		goto none;

	if (p4d_large(*p4d)) {
		page = p4d_page(*p4d);
		paddr = page_to_phys(page) + (vaddr & ~P4D_MASK);
		goto out;
	}

	pud = pud_offset(p4d, vaddr);
	if (bad_address(pud))
		goto bad;

	pr_cont("PUD %lx ", pud_val(*pud));
	if (!pud_present(*pud))
		goto none;

	if (pud_large(*pud)) {
		page = pud_page(*pud);
		paddr = page_to_phys(page) + (vaddr & ~PUD_MASK);
		goto out;
	}

	pmd = pmd_offset(pud, vaddr);
	if (bad_address(pmd))
		goto bad;

	pr_cont("PMD %lx ", pmd_val(*pmd));
	if (!pmd_present(*pmd))
		goto none;

	if (pmd_large(*pmd)) {
		page = pmd_page(*pmd);
		paddr = page_to_phys(page) + (vaddr & ~PMD_MASK);
		goto out;
	}

	pte = pte_offset_kernel(pmd, vaddr);
	if (bad_address(pte))
		goto bad;

	pr_cont("PTE %lx ", pte_val(*pte));
	if (pte_present(*pte)) {
		page = pte_page(*pte);
		paddr = page_to_phys(page) + (vaddr & ~PAGE_MASK);
	} else {
		pr_err("Invalid virtual address: 0x%lx\n", vaddr);
	}
out:
	pr_cont("\n");
	up_read(&mm->mmap_lock);
	rcu_read_unlock();
	return paddr;
bad:
	pr_err("bad address\n");
	up_read(&mm->mmap_lock);
	rcu_read_unlock();
	return paddr;
none:
	pr_err("no exist\n");
	up_read(&mm->mmap_lock);
	rcu_read_unlock();
	return paddr;
}

static int __init v2p_init(void)
{
	unsigned long paddr = v2p(pid, vaddr);
	if (paddr) {
		pr_info("Physical address for pid %d, virtual address 0x%lx: 0x%lx\n", pid, vaddr, paddr);
	} else {
		pr_err("Failed to get physical address\n");
	}
	return 0;
}

static void __exit v2p_exit(void)
{
	pr_info("Module exited\n");
}

module_init(v2p_init);
module_exit(v2p_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("l3b2w1");
MODULE_DESCRIPTION("get physical address from pid and virtual address");
```

### 获取memslot信息
```
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/mm.h>
#include <linux/kvm_host.h>
#include <linux/pid.h>
#include <linux/mm_types.h>
#include <linux/uaccess.h>

static int pid = -1;
module_param(pid, int, 0);
MODULE_PARM_DESC(pid, "PID of the QEMU process");

typedef unsigned long ulong;
static ulong gpa = -1;
module_param(gpa, ulong, 0);
MODULE_PARM_DESC(hva, "one gpa of the QEMU process");

static struct kvm *kvm;
static struct mm_struct *mm;
static struct task_struct *task;

static int bad_address(void *p)
{
	unsigned long dummy;

	return get_kernel_nofault(dummy, (unsigned long *)p);
}

static unsigned long v2p(int pid, unsigned long vaddr)
{
	struct task_struct *task;
	struct mm_struct *mm;
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;
	struct page *page;
	unsigned long paddr = 0;

	rcu_read_lock();
	task = pid_task(find_vpid(pid), PIDTYPE_PID);
	if (!task) {
		pr_err("No such process with pid: %d\n", pid);
		rcu_read_unlock();
		return 0;
	}

	mm = task->mm;
	if (!mm) {
		pr_err("Process %d does not have a valid memory descriptor\n", pid);
		rcu_read_unlock();
		return 0;
	}

	down_read(&mm->mmap_lock);

	pgd = pgd_offset(mm, vaddr);
	if (bad_address(pgd))
		goto bad;

	pr_info("PGD %lx ", pgd_val(*pgd));
	if (!pgd_present(*pgd))
		goto none;

	p4d = p4d_offset(pgd, vaddr);
	if (bad_address(p4d))
		goto bad;

	pr_cont("P4D %lx ", p4d_val(*p4d));
	if (!p4d_present(*p4d))
		goto none;

	if (p4d_large(*p4d)) {
		page = p4d_page(*p4d);
		paddr = page_to_phys(page) + (vaddr & ~P4D_MASK);
		goto out;
	}

	pud = pud_offset(p4d, vaddr);
	if (bad_address(pud))
		goto bad;

	pr_cont("PUD %lx ", pud_val(*pud));
	if (!pud_present(*pud))
		goto none;

	if (pud_large(*pud)) {
		page = pud_page(*pud);
		paddr = page_to_phys(page) + (vaddr & ~PUD_MASK);
		goto out;
	}

	pmd = pmd_offset(pud, vaddr);
	if (bad_address(pmd))
		goto bad;

	pr_cont("PMD %lx ", pmd_val(*pmd));
	if (!pmd_present(*pmd))
		goto none;

	if (pmd_large(*pmd)) {
		page = pmd_page(*pmd);
		paddr = page_to_phys(page) + (vaddr & ~PMD_MASK);
		goto out;
	}

	pte = pte_offset_kernel(pmd, vaddr);
	if (bad_address(pte))
		goto bad;

	pr_cont("PTE %lx ", pte_val(*pte));
	if (pte_present(*pte)) {
		page = pte_page(*pte);
		paddr = page_to_phys(page) + (vaddr & ~PAGE_MASK);
	} else {
		pr_err("Invalid virtual address: 0x%lx\n", vaddr);
	}
out:
	pr_cont("\n");
	up_read(&mm->mmap_lock);
	rcu_read_unlock();
	return paddr;
bad:
	pr_err("bad address\n");
	up_read(&mm->mmap_lock);
	rcu_read_unlock();
	return paddr;
none:
	pr_err("no exist\n");
	up_read(&mm->mmap_lock);
	rcu_read_unlock();
	return paddr;
}


static unsigned long gpa_to_hva(struct kvm *kvm, unsigned long gpa)
{
	unsigned long hva;

	hva = gfn_to_hva(kvm, gpa >> PAGE_SHIFT);

	return hva | (gpa & ~PAGE_MASK);
}

static void show_memslots_info(struct kvm *kvm)
{
	struct kvm_memslots *slots;
	struct kvm_memory_slot *memslot;

	mutex_lock(&kvm->slots_lock);

	slots = kvm_memslots(kvm);

	kvm_for_each_memslot(memslot, slots) {
		pr_err("[%s %d] host, base pfn 0x%7lx, npages %7lu, hva 0x%lx id %4d as_id %d\n",
				__func__, __LINE__, (unsigned long)memslot->base_gfn, memslot->npages,
				memslot->userspace_addr, memslot->id, memslot->as_id);
	}

	mutex_unlock(&kvm->slots_lock);
}

static struct kvm *get_kvm_from_pid(int pid)
{
	task = pid_task(find_vpid(pid), PIDTYPE_PID);
	if (!task) {
		pr_err("Task not found for PID: %d\n", pid);
		return NULL;
	}

	mm = get_task_mm(task);
	if (!mm) {
		pr_err("No mm_struct found for task with PID: %d\n", pid);
		return NULL;
	}

	kvm = mm_kvm(mm);
	if (!kvm) {
		pr_err("No KVM found for task with PID: %d\n", pid);
		return NULL;
	}

	kvm_get_kvm(kvm); // inc kvm ref

	return kvm;
}

static int __init gkvm_init(void)
{
	struct kvm *kvm;
	unsigned long hva;
	unsigned long hpa;

	if (pid < 0) {
		pr_err("Invalid PID: %d\n", pid);
		return -EINVAL;
	}

	kvm = get_kvm_from_pid(pid);
	if (!kvm) {
		pr_err("KVM struct not found for PID %d\n", pid);
		return -1;
	}

	show_memslots_info(kvm);

	hva = gpa_to_hva(kvm, gpa);

	hpa = v2p(pid, hva);

	pr_info("gpa 0x%lx, hva 0x%lx, hpa 0x%lx\n", gpa, hva, hpa);

	return 0;
}

static void __exit gkvm_exit(void)
{
	kvm_put_kvm(kvm);
	mmput(mm);

	pr_info("KVM module exited\n");
}

module_init(gkvm_init);
module_exit(gkvm_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("l3b2w1");
MODULE_DESCRIPTION("KVM Module to get misc info");
```

### acronyms
```
pfn   host page frame number
hpa   host physical address
hva   host virtual address
gfn   guest frame number
gpa   guest physical address
gva   guest virtual address
ngpa  nested guest physical address
ngva  nested guest virtual address
pte   page table entry (used also to refer generically to paging structure entries)
gpte  guest pte (referring to gfns)
spte  shadow pte (referring to pfns)
tdp   two dimensional paging (AMD's NPT and Intel's EPT)
```

### 参考索引
[linux-5.0](https://elixir.bootlin.com/linux/v5.10/source)  
