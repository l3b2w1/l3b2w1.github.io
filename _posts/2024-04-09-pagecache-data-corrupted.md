---
layout:     post
title:      pagecache data corrupted
subtitle:   pagecache页面数据被写坏
date:       2024-04-09
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - memory
    - arm64
---

## 简介
产品反馈虚拟机环境，内存配置为8G，升级版本时提示数据校验不过，然后升级失败。

4G内存配置无该问题。host是鲲鹏服务器，kunpeng-920处理器。

同样的虚拟机配置使用其它ubuntu或者centos的系统镜像，虚拟机都没有出现该问题。


## 定位过程
尝试在虚机设备上升级失败后计算版本文件的MD5值，每次都会变化。  
drop_cache之后计算版本文件的md5值是正确的，后续计算的MD5值都是错误的，而且一直在变化。  

每次MD5计算出错后，cp拷贝多份版本文件导出，  
和正常版本文件对比发现，固定偏移处总有两处几个字节的变化，不像是单个bit位跳变，没有规律。

flash上的版本文件是没有改动的。因为清缓存后重新计算版本文件的MD5值是正确的。  
既然没有造成page dirty，同一个页面也不太可能分配给两个不同的进程，所以不倾向于pagecache机制问题，不倾向于内存分配问题。

测试偶然发现和配置telnet连接有关，不配置telnet，串口执行md5 ipe不会变化；开启关闭一个telnet口，md5 ipe值也可能会变化。  
telnet端口没有命令交互的话，大概几十秒左右md5值不会变化，但是几十秒之后会变，猜测可能和网络保活有关。  

虚机镜像系统内核不支持硬件断点，启用了kasan的版本也没跑出来什么东西。

#### 查找被修改的page
先看看pagecache里的数据到底哪里被改了

写了个测试模块，遍历文件在pagecache中的所有的page，计算page页面数据的MD5值。  

然后输出pfn、virtual address、physical address，以及md5值到trace缓冲区。  

每次在MD5值出现变化后执行insmod ko 然后rmmod ko，拿到多次打印记录做对比。   
两个page的MD5值一直在变，其它page数据MD5都是一样的。  

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2024-04-09-pagecache-data-corrupted-0.png)
#### 打印page内容
再写一个测试模块，根据指定pfn号，打印出这两个页面数据，然后多次数据记录做对比。  
确实这两个page里固定偏移处的一两个字节在变。

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2024-04-09-pagecache-data-corrupted-1.png)

#### 设置页面写保护
之前遇到过只读页面写入数据时触发保护异常的情况，既然出问题的page pfn固定，就想着能不能利用这种方式抓下。  

写一个测试模块，根据pfn号，找到对应的pte表项，修改为只读权限。希望可以抓到写越界的罪魁祸首。

一旦telnet命令交互产生网络数据，如果写到pagecache的这两个页面，那理应抓得到。

执行命令`insmod pgrdonly.ko pfn=2238397`之后，telnet端口随便执行一些命令，系统随即触发了保护异常。  
`0xffff0001e27aa6a6`就位于`pfn = 2238397`的页面内部，`0x6a6`的页内偏移也和页面数据对比中的偏移一致。  
可以看到是模块`wan`协议栈代码写越界。  
```
<1>[  796.021377] Unable to handle kernel write to read-only memory at virtual address ffff0001e27aa6a6
<1>[  796.022942] Mem abort info:
<1>[  796.023373]   ESR = 0x9600004f
<1>[  796.023912]   EC = 0x25: DABT (current EL), IL = 32 bits
<1>[  796.024764]   SET = 0, FnV = 0
<1>[  796.025232]   EA = 0, S1PTW = 0
<1>[  796.025737] Data abort info:
<1>[  796.026185]   ISV = 0, ISS = 0x0000004f
<1>[  796.026812]   CM = 0, WnR = 1
<1>[  796.027278] swapper pgtable: 4k pages, 48-bit VAs, pgdp=0000000040a66000
<1>[  796.028376] [ffff0001e27aa6a6] pgd=000000023fff8003, pud=000000023f044003, pmd=000000023ef30003, pte=00e00002227aa793
<0>[  796.030145] Internal error: Oops: 9600004f [#1] SMP
<4>[  796.030936] Modules linked in: wan(PO) vsr(O) [last unloaded: pgrdonly]
<4>[  796.032370] CPU: 1 PID: 1993 Comm: kdrvfwdd1 Tainted: P           O      5.4.90 #1
<4>[  796.033595] Hardware name: QEMU KVM Virtual Machine, BIOS 0.0.0 02/06/2015
<4>[  796.034707] pstate: 60400005 (nZCv daif +PAN -UAO)
<4>[  796.037144] pc : ip_newid+0x4c/0x70 [wan]
<4>[  796.039317] lr : ip_newid+0x1c/0x70 [wan]
<4>[  796.040064] sp : ffff00019f6ce420
<4>[  796.040677] x29: ffff00019f6ce420 x28: 0000000000000000
<4>[  796.041619] x27: ffff000194cf43c8 x26: ffff800028963348
<4>[  796.042483] x25: ffff800008beae2c x24: ffff0001c0bb82d0
<4>[  796.043351] x23: ffff0001c00ef8f0 x22: ffff800028ea0858
<4>[  796.044209] x21: ffff000194238000 x20: ffff000194cf4380
<4>[  796.045114] x19: 0000000000000048 x18: ffff800028a04b18
<4>[  796.045984] x17: 0000000000000001 x16: ffff800028770420
<4>[  796.046886] x15: 0000000010000000 x14: ffff800029973000
<4>[  796.047754] x13: 0000000000000001 x12: 00000000ffffffff
<4>[  796.048645] x11: ffff800041f01000 x10: 0000000000000a00
<4>[  796.049515] x9 : ffff80002819c458 x8 : ffff00019f6ce4d0
<4>[  796.050367] x7 : 0000000000000000 x6 : 0000000000000001
<4>[  796.051256] x5 : 0000000000000000 x4 : ffff000194238000
<4>[  796.052143] x3 : ffff800028d66000 x2 : 0000000000000005
<4>[  796.053014] x1 : 000000000000f07e x0 : ffff0001e27aa6a6
<4>[  796.053891] Call trace:
<4>[  796.055566]  ip_newid+0x4c/0x70 [wan]
<4>[  796.057519]  tcp_output+0x26c4/0x2d00 [wan]
<4>[  796.059676]  tcp_do_segment+0xfd0/0x43e0 [wan]
<4>[  796.061788]  tcp_input+0x277c/0x2ba0 [wan]
<4>[  796.063818]  ip_protoinput+0xa8/0xd0 [wan]
...... // 省去部分业务栈
<4>[  796.099035]  kthread+0x12c/0x130
<4>[  796.099546]  ret_from_fork+0x10/0x18
<0>[  796.100167] Code: 79400000 0b000020 12003c01 f9400fe0 (79000001)
<4>[  796.101154] task_switch hooks:
[1]kdb>
```
-----------------------------------------------------------------------------
## 模块代码
#### md5sum pagecache pages
```
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/pagemap.h>
#include <linux/highmem.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/sched.h>
#include <linux/namei.h>
#include <linux/fs_struct.h>
#include <linux/mount.h>
#include <linux/path.h>
#include <linux/crypto.h>
#include <crypto/hash.h>
#include <linux/hash.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mm_types.h>


#define MD5_DIGEST_LENGTH 16

static void calculate_md5(const char *data, size_t len, char *digest)
{
	struct crypto_shash *tfm;
	struct shash_desc *desc;
	char hex_digest[MD5_DIGEST_LENGTH * 2 + 1] = {0}; // 十六进制表示MD5值
	char *hash;
	int ret;

	tfm = crypto_alloc_shash("md5", 0, 0);
	if (IS_ERR(tfm)) {
		pr_err("Failed to allocate transform for MD5\n");
		return;
	}

	desc = kmalloc(sizeof(struct shash_desc) + crypto_shash_descsize(tfm),
			GFP_KERNEL);
	if (!desc) {
		pr_err("Failed to allocate shash descriptor for MD5\n");
		crypto_free_shash(tfm);
		return;
	}

	desc->tfm = tfm;

	ret = crypto_shash_init(desc);
	if (ret) {
		pr_err("Failed to initialize MD5 hash\n");
		kfree(desc);
		crypto_free_shash(tfm);
		return;
	}

	ret = crypto_shash_update(desc, data, len);
	if (ret) {
		pr_err("Failed to update MD5 hash\n");
		kfree(desc);
		crypto_free_shash(tfm);
		return;
	}

	hash = kmalloc(MD5_DIGEST_LENGTH, GFP_KERNEL);
	if (!hash) {
		pr_err("Failed to allocate memory for MD5 hash\n");
		kfree(desc);
		crypto_free_shash(tfm);
		return;
	}

	ret = crypto_shash_final(desc, hash);
	if (ret) {
		pr_err("Failed to finalize MD5 hash\n");
		kfree(hash);
		kfree(desc);
		crypto_free_shash(tfm);
		return;
	}
	bin2hex(hex_digest, hash, MD5_DIGEST_LENGTH);
	memcpy(digest, hex_digest, MD5_DIGEST_LENGTH * 2 + 1);

	kfree(hash);
	kfree(desc);
	crypto_free_shash(tfm);
}

static int print_page_md5(const char *filename)
{
	struct file *file;
	struct path path;
	struct inode *inode;
	struct page *page;
	unsigned long index;
	unsigned long phys_addr;
	unsigned long pfn;
	char *data;
	char digest[MD5_DIGEST_LENGTH * 2 + 1] = {0}; // 十六进制表示MD5值

	if (kern_path(filename, LOOKUP_FOLLOW, &path)) {
		printk(KERN_ERR "Failed to get path for file: %s\n", filename);
		return -ENOENT;
	}

	file = filp_open(filename, O_RDONLY, 0);
	if (IS_ERR(file)) {
		printk(KERN_ERR "Failed to open file: %s\n", filename);
		return PTR_ERR(file);
	}

	inode = file_inode(file);

	index = 0;
	while ((page = find_get_page(inode->i_mapping, index))) {
		pfn = page_to_pfn(page);
		phys_addr = page_to_phys(page);

		data = kmap(page);
		if (!data) {
			printk(KERN_ERR "Failed to map page data\n");
			put_page(page);
			continue;
		}

		calculate_md5(data, PAGE_SIZE, digest);
		trace_printk("%lu: pfn %lu, va 0x%lx, pa 0x%lx, md5 %s\n", index, pfn, (unsigned long)data, phys_addr, digest);

		kunmap(page);
		put_page(page);
		index++;

		cond_resched();
	}

	filp_close(file, NULL);
	return 0;
}

static int __init pg_init(void)
{
	const char *filename = "/mnt/flash/ipe";
	pr_err("[%s %d] pc, filename %s\n", __func__, __LINE__, filename);
	print_page_md5(filename);
	return 0;
}

static void __exit pg_exit(void)
{
	printk(KERN_INFO "Exiting pagecache_md5 module\n");
}

module_init(pg_init);
module_exit(pg_exit);
```
#### dump page content
```
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/pagemap.h>
#include <linux/highmem.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/sched.h>
#include <linux/namei.h>
#include <linux/fs_struct.h>
#include <linux/mount.h>
#include <linux/path.h>
#include <linux/crypto.h>
#include <crypto/hash.h>
#include <linux/hash.h>
#include <asm/delay.h>
#include <linux/delay.h>
#include <linux/printk.h>

unsigned char cont[PAGE_SIZE] = {0};

typedef unsigned long ulong;
unsigned long pfn;
module_param(pfn, ulong, S_IRUGO);

static void print_page(unsigned long pfn)
{
	struct page *page;
	unsigned char *data;
	unsigned long phys_addr;

	page = pfn_to_page(pfn);
	phys_addr = page_to_phys(page);

	data = kmap(page);
	if (!data) {
		printk(KERN_ERR "Failed to map page data\n");
		put_page(page);
		return;
	}
	memcpy(cont, data, PAGE_SIZE);

	pr_err("pfn %lu, va 0x%lx, pa 0x%lx\n", pfn, (unsigned long)data, phys_addr);
	pr_err("------------------------------------------\n");
	print_hex_dump(KERN_ERR, "", DUMP_PREFIX_OFFSET, 16, 1, cont, PAGE_SIZE, true);
	pr_err("------------------------------------------\n");

	kunmap(page);
	put_page(page);
}

static int __init pc_init(void)
{
	pr_err("[%s %d] h3c, hello print page content pfn 2238334,2238397,2238000\n", __func__, __LINE__);
	print_page(2238334);
	print_page(2238397);
	print_page(2238000);
	return 0;
}

static void __exit pc_exit(void)
{
	printk(KERN_INFO "Exiting print page content module\n");
}

module_init(pc_init);
module_exit(pc_exit);
```
#### set page read-only
```
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/pagemap.h>
#include <linux/highmem.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/sched.h>
#include <linux/namei.h>
#include <linux/fs_struct.h>
#include <linux/mount.h>
#include <linux/path.h>
#include <linux/crypto.h>
#include <crypto/hash.h>
#include <linux/hash.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/pfn.h>
#include <linux/slab.h>
#include <linux/kallsyms.h>
#include <asm/pgtable.h>

#include <asm/page.h>
#include <asm/pgalloc.h>

typedef unsigned long ulong;

static unsigned long pfn;

module_param(pfn, ulong, S_IRUGO);

struct mm_struct *pmm = NULL;

static pte_t *get_pte(unsigned long addr)
{
	struct mm_struct *mm = pmm;
	pgd_t *pgdp, pgd;
	pud_t *pudp, pud;
	pmd_t *pmdp, pmd;
	pte_t *ptep = NULL, pte;

	pr_err("[%s %d] pc, init_mm 0x%lx, page addr 0x%lx\n", __func__, __LINE__, (unsigned long)pmm, addr);

	pgdp = pgd_offset(mm, addr);
	pgd = READ_ONCE(*pgdp);
	pr_err("[%016lx] pgd=%016llx\n", addr, pgd_val(pgd));

	if (pgd_none(pgd) || pgd_bad(pgd)) {
		pr_err("[%s %d] pc, pgd invalid\n", __func__, __LINE__);
		return 0;
	}

	pudp = pud_offset(pgdp, addr);
	pud = READ_ONCE(*pudp);
	pr_err("pud=%016llx\n", pud_val(pud));
	if (pud_none(pud) || pud_bad(pud)) {
		pr_err("[%s %d] pc, pud invalid\n", __func__, __LINE__);
		return 0;
	}

	pmdp = pmd_offset(pudp, addr);
	pmd = READ_ONCE(*pmdp);
	pr_err("pmd=%016llx\n", pmd_val(pmd));
	if (pmd_none(pmd) || pmd_bad(pmd)) {
		pr_err("[%s %d] pc, pmd invalid\n", __func__, __LINE__);
		return 0;
	}

	ptep = pte_offset_map(pmdp, addr);
	pte = READ_ONCE(*ptep);
	if (!pte_valid(READ_ONCE(*ptep))) {
		pr_err("[%s %d] pc, pte invalid\n", __func__, __LINE__);
		return 0;
	}
	pr_err("pte=%016llx\n", pte_val(pte));

	return ptep;
}

static void set_pte_rdonly(pte_t *ptep, unsigned long address)
{
	pte_t pte;
	pte = READ_ONCE(*ptep);
	pr_err("[%s %d] pc, pte value 0x%lx before set rdonly\n", __func__, __LINE__, (unsigned long)pte_val(pte));
	pte = pte_wrprotect(pte);
	pr_err("[%s %d] pc, pte value 0x%lx construct wrprotect\n", __func__, __LINE__, (unsigned long)pte_val(pte));
	set_pte_at(pmm, address, ptep, pte);
	pr_err("[%s %d] pc, pte value 0x%lx after set\n", __func__, __LINE__, (unsigned long)pte_val(READ_ONCE(*ptep)));
	flush_tlb_all();
}

static void write_rdonly_page(unsigned long addr)
{
	memset((void*)addr, 0x0, PAGE_SIZE);
}

static void set_page_rdonly(unsigned long pfn)
{
	struct page *page = NULL;
	unsigned long address;
	pte_t *ptep;

	pr_err("[%s %d] pc, pfn %lu\n", __func__, __LINE__, pfn);
	page = pfn_to_page(pfn);
	if (!page) {
		pr_err("[%s %d] pc, get pfn %lu page failure\n", __func__, __LINE__, pfn);
		return;
	}

	pr_err("[%s %d] pc, page 0x%lx\n", __func__, __LINE__, (unsigned long)page);

	address = (unsigned long)page_address(page);
	pr_err("[%s %d] pc, page address 0x%lx\n", __func__, __LINE__, address);

	ptep = get_pte(address);
	pr_err("[%s %d] pc, ptep 0x%lx\n", __func__, __LINE__, (unsigned long)ptep);

	set_pte_rdonly(ptep, address);
}

static void set_alloc_page_rdonly(void)
{
	struct page *page;
	unsigned long address;
	pte_t *ptep;

	page = alloc_page(GFP_KERNEL);
	if (!page) {
		pr_err("[%s %d] pc, alloc_page failure\n", __func__, __LINE__);
		return;
	}

	pr_err("[%s %d] pc, page 0x%lx\n", __func__, __LINE__, (unsigned long)page);

	address = (unsigned long)page_address(page);
	pr_err("[%s %d] pc, page address 0x%lx\n", __func__, __LINE__, address);
	ptep = get_pte(address);

	pr_err("[%s %d] pc, ptep 0x%lx\n", __func__, __LINE__, (unsigned long)ptep);
	set_pte_rdonly(ptep, address);
}

static int __init pg_init(void)
{
	pmm = (struct mm_struct *)kallsyms_lookup_name("init_mm");
	if (!pmm) {
		pr_err("[%s %d] pc, find init_mm failure\n", __func__, __LINE__);
		return -1;
	}

	pr_err("[%s %d] pc, init_mm addr 0x%lx\n", __func__, __LINE__, (unsigned long)pmm);
	set_page_rdonly(pfn);
	/*set_alloc_page_rdonly();*/
	return 0;
}

static void __exit pg_exit(void)
{
	pr_err("Exiting set page readlony module\n");
}

module_init(pg_init);
module_exit(pg_exit);
```

## 参考
[linux-5.4.90](https://elixir.bootlin.com/linux/v5.4.90/source/)
