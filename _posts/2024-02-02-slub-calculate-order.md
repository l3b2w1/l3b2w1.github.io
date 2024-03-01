---
layout:     post
title:      slub calculate order
subtitle:   创建kmem cache时计算page order
date:       2024-02-02
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - memory
    - slub
---

## 简介
slub kmem cache创建过程中需要根据object_size计算分配的page的阶数order。  
分配的阶数对性能和其他系统组件会有重要影响。

`PAGE_ALLOC_COSTLY_ORDER` 是内存分配场合的一个概念，  
如果申请的内存 `order > PAGE_ALLOC_COSTLY_ORDER`时就认为本次分配是昂贵的，    
`order <= PAGE_ALLOC_COSTLY_ORDER` 的申请更容易得到满足。
```
/*
 * PAGE_ALLOC_COSTLY_ORDER is the order at which allocations are deemed
 * costly to service.  That is between allocation orders which should
 * coalesce naturally under reasonable reclaim pressure and those which
 * will not.
 */
#define PAGE_ALLOC_COSTLY_ORDER 3
```

内存申请慢速路径上申请超过8个page会被认为是costly，除非提供了`__GFP_RETRY_MAYFAIL`标记，否则返回失败  
```
static inline struct page *
__alloc_pages_slowpath(gfp_t gfp_mask, unsigned int order,
						struct alloc_context *ac)
{
	bool can_direct_reclaim = gfp_mask & __GFP_DIRECT_RECLAIM;
	const bool costly_order = order > PAGE_ALLOC_COSTLY_ORDER;
  ...
  /*
  * Do not retry costly high order allocations unless they are
  * __GFP_RETRY_MAYFAIL
  */
  if (costly_order && !(gfp_mask & __GFP_RETRY_MAYFAIL))
    goto nopage;
  ...
```

## calculate_order
calculate_order 尝试找到最佳的 slab 配置。  

slub_max_order即`PAGE_ALLOC_COSTLY_ORDER`, 是一个分水岭。  
如果达到 slub_max_order，则尽量保持页面阶数尽量低。因此，接受更多的空间浪费，以换取较小的页面阶数。

1. 对于较小的object size， 首选阶数 0 的分配，因为阶数 0 不会导致页面分配器中的碎片。  
但是较大的对象放入阶数 0 的 slab，因为可能会有太多未使用的空间。  
所以为了满足小于既定比例的浪费空间，循环尝试:   
a. 增大阶数，但是最大阶数不超过slub_max_order。    
b. 降低slub可以容纳的object的最小个数，但是至少要包含一个object。  
如果仍然失败，则继续执行下去。

2. 对于稍大的object size，order不超过slub_max_order，一个slub里只会放一个object。

3. 对于更大的object size, 允许order不大于MAX_ORDER，一个slub里只会放一个object。


这里的入参size其实已经已经是object_size经过各种配置和条件对齐之后的大小(比如打开slub_debug开关等)
```
static inline int calculate_order(unsigned int size)
{
	unsigned int order;
	unsigned int min_objects;
	unsigned int max_objects;

	min_objects = slub_min_objects;
	if (!min_objects)
		min_objects = 4 * (fls(nr_cpu_ids) + 1);
	max_objects = order_objects(slub_max_order, size);
	min_objects = min(min_objects, max_objects);

	while (min_objects > 1) {      // --------------------- 1
		unsigned int fraction;

		fraction = 16;  // 尝试碎片比例依次为1/16  1/8  1/4
		while (fraction >= 4) {
			order = slab_order(size, min_objects,
					slub_max_order, fraction);
			if (order <= slub_max_order)
				return order;
			fraction /= 2;
		}
		min_objects--;
	}

	/*
	 * We were unable to place multiple objects in a slab. Now
	 * lets see if we can place a single object there.
	 */
	 // 尝试一个slab中只包含一个object，由此分配的page order不超过slub_max_order(3)
	order = slab_order(size, 1, slub_max_order, 1);  // --------------------- 2
	if (order <= slub_max_order)
		return order;

	/*
	 * Doh this slab cannot be placed using slub_max_order.
	 */
	 // object_size 比较大，比如64k
	 // 尝试一个slab只包含一个object，可以使用更大的order，但是不能超过MAX_ORDER
	order = slab_order(size, 1, MAX_ORDER, 1);   // --------------------- 3
	if (order < MAX_ORDER)
		return order;
	return -ENOSYS;
}

static inline unsigned int slab_order(unsigned int size,
		unsigned int min_objects, unsigned int max_order,
		unsigned int fract_leftover)
{
	unsigned int min_order = slub_min_order;
	unsigned int order;

	if (order_objects(min_order, size) > MAX_OBJS_PER_PAGE)
		return get_order(size * MAX_OBJS_PER_PAGE) - 1;

	for (order = max(min_order, (unsigned int)get_order(min_objects * size));
			order <= max_order; order++) {

		unsigned int slab_size = (unsigned int)PAGE_SIZE << order;
		unsigned int rem;

		rem = slab_size % size; // rem 即为浪费空间大小

		if (rem <= slab_size / fract_leftover)   //浪费空间是否小于规定比例(1/16 1/8 1/4)
			break;
	}

	return order;
}
```


## 参考
[linux-5.4.74](https://elixir.bootlin.com/linux/v5.4.74/source/mm/slub.c)
