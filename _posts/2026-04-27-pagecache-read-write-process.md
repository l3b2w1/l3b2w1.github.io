---
layout:     post
title:      trace vfs read/write
subtitle:   读写流程跟踪
date:       2026-04-27
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - pagecache
    - trace
---
研究`pagecache`相关代码，可以利用`ftrace`获取各个关键流程。  
如下是在嵌入式环境，利用 `ftrace` 跟踪 vfs read write 的过程。   

## 测试命令
```
# df -T
Filesystem           Type       1K-blocks      Used Available Use% Mounted on
devtmpfs             devtmpfs    12101536         0  12101536   0% /dev
tmpfs                tmpfs       12217504       128  12217376   0% /tmp
tmpfs                tmpfs       12217504        16  12217488   0% /run
/dev/mmcblk0p2       ext4         8256952        12   7837512   0% /mnt/mmc
tmpfs                tmpfs       12217504         0  12217504   0% /dev/shm
# echo 3 > /proc/sys/vm/drop_caches
# taskset -c 16 dd if=/mnt/mmc/zerofile of=/mnt/mmc/zerofile2 bs=1k count=8 2>/dev/null
# taskset -c 16 dd if=/mnt/mmc/zerofile of=/mnt/mmc/zerofile2 bs=1k count=8 2>/dev/null
```

## 日志分析
![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-04-27-pagecache-flowchart.png)

#### ext4 读路径分析（冷读触发预读）
trace 显示 ext4_file_read_iter 被调用，是从 ext4 文件冷读时的标准调用链。关键路径如下：
```
vfs_read()
  rw_verify_area()
  __vfs_read()
    new_sync_read()
      ext4_file_read_iter()
        generic_file_read_iter()
          pagecache_get_page.part.59()               ### 查找页缓存，首次未命中 ###
          page_cache_sync_readahead()                # 触发同步预读
            ondemand_readahead()
              __do_page_cache_readahead()
                __page_cache_alloc()                 # 分配多个页
                read_pages()
                  ext4_readpages()
                    ext4_mpage_readpages()
                      add_to_page_cache_lru()        # 加入 page cache
                      ext4_map_blocks()              # 逻辑块到物理块映射
                        ext4_es_lookup_extent()
                        ext4_ind_map_blocks()
                          ext4_block_to_path.isra.9()
                          ext4_get_branch()
                        ext4_es_insert_extent()
                      bio_alloc_bioset()             # 分配 bio
                        mempool_alloc()
                          mempool_alloc_slab()
                            kmem_cache_alloc()
                      bio_associate_blkg()           # 关联 cgroup
                      bio_add_page()                 # 填充 bio 页
                      submit_bio()                   # 提交 bio
                        generic_make_request()
                          generic_make_request_checks()
                          blk_mq_make_request()
                            __blk_queue_split()
                            __blk_mq_sched_bio_merge()  # 尝试合并 bio
                              dd_bio_merge()
                                blk_mq_sched_try_merge()
                            blk_mq_get_request()        # 获取请求
                            blk_account_io_start()
                            blk_add_rq_to_plug()        # 加入 plug 队列
                      put_pages_list()
                      blk_finish_plug()                 # 冲刷 plug 队列
                        blk_flush_plug_list()
                          blk_mq_flush_plug_list()
                            blk_mq_sched_insert_requests()
                              dd_insert_requests()       # deadline 调度器
                                blk_mq_run_hw_queue()    # 唤醒硬件队列
                                  __blk_mq_delay_run_hw_queue()
                                    kblockd_mod_delayed_work_on()  # 异步派发 I/O
          pagecache_get_page.part.59()                # 再次查找，命中并标记访问
          mark_page_accessed()
```
**关键点：**
1. **冷读触发批量预读**：首次 `pagecache_get_page` 未命中，触发 `page_cache_sync_readahead`，一次性分配多个页并通过 `ext4_readpages` 批量提交 I/O。
2. **ext4 块映射**：`ext4_map_blocks` 结合 extent tree 查找（`ext4_es_lookup_extent`）或间接块映射（`ext4_ind_map_blocks`）完成逻辑块到物理块的转换。
3. **块层提交流程**：`submit_bio` 进入 `generic_make_request`，经由 `blk_mq_make_request` 将 bio 转换为请求，并利用 `blk_add_rq_to_plug` 暂存请求，最后在 `blk_finish_plug` 时批量下发到调度器。
4. **异步 I/O 完成**：`blk_mq_run_hw_queue` 通过 `kblockd_mod_delayed_work_on` 交给 workqueue 异步执行，实际 eMMC 驱动函数（如 `mmc_mq_queue_rq`）不在此堆栈内。  

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-04-27-vfs-read.png)

#### ext4 写路径分析（延迟分配）  
写路径 trace 显示：
```
vfs_write()
  rw_verify_area()
  __sb_start_write()
  __vfs_write()
    new_sync_write()
      ext4_file_write_iter()
        generic_write_check_limits.isra.60()
        __generic_file_write_iter()
          file_remove_privs()
          generic_perform_write()
            ext4_da_write_begin()                       # 延迟分配写开始
              grab_cache_page_write_begin()
                pagecache_get_page.part.59()            ### 获取或创建页缓存页 ###
                  find_get_entry()
                  __page_cache_alloc()
                    alloc_pages_current()
                      __alloc_pages_nodemask()
                        get_page_from_freelist()
                  add_to_page_cache_lru()
                    __add_to_page_cache_locked()
                      mem_cgroup_try_charge()
                      __inc_node_page_state()
                      mem_cgroup_commit_charge()
                    lru_cache_add()
              unlock_page()
              __ext4_journal_start_sb()                 # 开启日志
              __block_write_begin()                     # 准备写入
                create_page_buffers()
                ext4_da_get_block_prep()                # 预留磁盘空间
                  ext4_es_lookup_extent()
                  ext4_ind_map_blocks()
                  ext4_da_reserve_space()
                    __dquot_alloc_space()
                    ext4_claim_free_clusters()
                  ext4_es_insert_delayed_block()        # 标记延迟分配块
                clean_bdev_aliases()
                flush_dcache_page()
            flush_dcache_page()
            ext4_da_write_end()                         # 延迟分配写完成
              generic_write_end()
                block_write_end()
                  __block_commit_write.isra.41()
                    mark_buffer_dirty()                 # 标记 bh 脏
                      lock_page_memcg()
                      __set_page_dirty()
                        account_page_dirtied()
                      __mark_inode_dirty()
                unlock_page()
                __mark_inode_dirty()               # inode 被标记为脏，唤醒回写线程   
                  ext4_dirty_inode()
                    ext4_mark_inode_dirty()
                      ext4_reserve_inode_write()
                        __ext4_get_inode_loc()
                        __ext4_journal_get_write_access()
                      ext4_mark_iloc_dirty()
                    __ext4_journal_stop()
            _cond_resched()
            balance_dirty_pages_ratelimited()
  __sb_end_write()
```
**关键点：**
1. **延迟分配**：`ext4_da_write_begin` 中通过 `ext4_da_reserve_space` 在内存中预留块并标记延迟分配（`ext4_es_insert_delayed_block`），实际磁盘空间在稍后的 writeback 时分配。
2. **日志保护**：`__ext4_journal_start_sb` / `__ext4_journal_stop` 将写操作包裹在 ext4 日志事务中，确保持久性。
3. **脏页标记与写回**：`mark_buffer_dirty` 标记 buffer head 为脏，`__set_page_dirty` 通过 `account_page_dirtied` 更新页脏统计数据。
4. **inode 脏标记**：`ext4_mark_inode_dirty` 负责更新 inode 元数据（如 `ext4_reserve_inode_write`），并同样通过日志保护。

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-04-27-vfs-write.png)

#### minor fault

当页缓存中已有文件数据时，缺页处理直接建立映射：
```
do_page_fault()
  down_read_trylock()
  find_vma()
    vmacache_find()
  handle_mm_fault()
    mem_cgroup_from_task()
    __handle_mm_fault()
      filemap_map_pages()
        PageHuge()
        alloc_set_pte()                # 设置页表项
          add_mm_counter_fast()
          page_add_file_rmap()
            lock_page_memcg()
            unlock_page_memcg()
          __sync_icache_dcache()
        unlock_page()
        ... (重复多次 alloc_set_pte)
```
**关键点：**
1. **无需 I/O**：整个路径未出现 `__do_fault` 或 `readpage`，表明所需页面已在页缓存中。
2. **批量映射**：`filemap_map_pages` 遍历页缓存中的一批页面，通过 `alloc_set_pte` 直接为其建立页表映射，并更新 rmap。
3. **性能优势**：minor fault 仅涉及内存操作，延迟极低，是 mmap 高效性的关键。


#### major fault（ext4 文件写时复制）

major fault 发生在需要从磁盘读取数据或进行写时复制时，trace 中显示了 ext4 文件的写时复制流程：
```
do_page_fault()
  down_read_trylock()
  find_vma()
  handle_mm_fault()
    __handle_mm_fault()
      do_wp_page()                            # 写时复制缺页
        vm_normal_page()
        wp_page_copy()
          __anon_vma_prepare()                # 准备匿名 VMA
            kmem_cache_alloc()
            find_mergeable_anon_vma()
          alloc_pages_vma()                    # 分配新物理页
            __get_vma_policy()
              shmem_get_policy()               # 日志中文件策略来自 shmem，但文件为 ext4
            get_vma_policy()
            __alloc_pages_nodemask()
              get_page_from_freelist()
          __cpu_copy_user_page()               # 拷贝旧页内容
          mem_cgroup_try_charge_delay()
          add_mm_counter_fast()
          ptep_clear_flush()                   # 清除旧页表项
          page_add_new_anon_rmap()
          mem_cgroup_commit_charge()
          lru_cache_add_active_or_unevictable()
          page_remove_rmap()                   # 移除旧页的 rmap
```
**关键点：**
1. **写时复制**：当对 mmap 共享映射的 ext4 文件进行写操作时，触发 `do_wp_page`，通过 `wp_page_copy` 分配新页并复制数据。
2. **匿名页转换**：复制后的新页通过 `page_add_new_anon_rmap` 转为匿名页，脱离与文件页缓存的直接关联。
3. **页面分配**：`alloc_pages_vma` 分配零阶页，若内存紧张可能涉及内存回收。测试环境系统内存充足，因而trace 中未出现 `shrink` 相关调用。
4. **元数据更新**：更新 rss 计数器、内存 cgroup 统计，并将旧页的脏标记转移到新页（`page_remove_rmap`）。

此 major fault 流程展示了 ext4 文件 mmap 写入时的关键路径，确保进程对映射文件的修改不会影响页缓存中的原始数据。


#### __mark_inode_dirty

第一个 `__mark_inode_dirty` 调用，内部执行了一条非常关键的路径：

```
__mark_inode_dirty
  ├─ locked_inode_to_wb_and_lock_list()    // 将 inode 挂入对应 backing device 的脏链表
  ├─ inode_io_list_move_locked()          // 在 wb 的链表上移动该 inode
  │    └─ wb_io_lists_populated()         // 确认链表是否已初始化
  └─ wb_wakeup_delayed()                  // *** 唤醒回写 work ***
       ├─ __msecs_to_jiffies()            // 计算延迟时间
       ├─ queue_delayed_work_on()         // 把回写 work 排入 workqueue
       │    └─ __queue_delayed_work()
       │         └─ add_timer()           // 设置定时器，到期后触发 kworker 执行
       │              ├─ calc_wheel_index()
       │              └─ enqueue_timer()
       └─ ... (软中断开关)
```
**交互的子系统**：
- **VFS inode cache**：`locked_inode_to_wb_and_lock_list` 将 inode 加入 backing device 的脏 inode 链表。
- **writeback 框架**：`wb_wakeup_delayed` → `queue_delayed_work_on` 将 `wb_workfn` 作为延迟 work 放入 workqueue，由 kworker 线程执行。
- 实际是由系统里的**[kworker/u48:3-events_unbound]**代为执行的。

```
# dd if=/dev/zero of=/mnt/mmc/bigfile3 bs=1M count=4
4+0 records in
4+0 records out
# cd /sys/kernel/tracing/
# cat trace
# tracer: nop
#
# entries-in-buffer/entries-written: 3/3   #P:24
#
#                                _-----=> irqs-off
#                               / _----=> need-resched
#                              | / _---=> hardirq/softirq
#                              || / _--=> preempt-depth
#                              ||| /     delay
#           TASK-PID     CPU#  ||||   TIMESTAMP  FUNCTION
#              | |         |   ||||      |         |
           <...>-141     [003] ....    54.177730: <stack trace>
 => do_writepages
 => __writeback_single_inode
 => writeback_sb_inodes
 => __writeback_inodes_wb
 => wb_writeback
 => wb_workfn
 => process_one_work
 => worker_thread
 => kthread
 => ret_from_fork

# ps aux|grep 141
root       141  0.0  0.0      0     0 ?        I    00:00   0:00 [kworker/u48:3-events_unbound]
```


## 跟踪脚本
```
#!/bin/sh
set -x

FUNCTION=$1

TRACING_DIR=/sys/kernel/tracing

# 进入 tracing 目录
cd $TRACING_DIR || exit 1

# 1. 停止当前追踪
echo 0 > tracing_on

# 2. 清空原来的 trace 数据和过滤器
echo > trace
echo > set_graph_function
echo > set_graph_notrace
echo > set_ftrace_filter
echo > set_ftrace_notrace

# 3. 设置追踪器为 function_graph
echo function_graph > current_tracer

# 4. 入参函数作为“根函数”展开调用图
#echo "$FUNCTION" >> set_graph_function
echo vfs_read  >> set_graph_function
echo vfs_write >> set_graph_function
echo filemap_fault >> set_graph_function
echo do_wp_page >> set_graph_function
echo do_mmap >> set_graph_function
echo do_page_fault >> set_graph_function

# 5. 配置图形输出选项，减少干扰
echo 0 > options/funcgraph-irqs       # 不显示中断处理函数
#echo 0 > options/funcgraph-proc       # 不显示进程名（可选）
#echo 32 > max_graph_depth             # 限制深度，避免刷屏
echo 1 > options/funcgraph-tail       # 显示函数结尾

# show process comm pid
echo funcgraph-proc > trace_options
echo funcgraph-abstime > trace_options

# 6. 批量过滤无关函数
# 锁操作
echo mutex_lock        >> set_graph_notrace
echo mutex_unlock      >> set_graph_notrace
echo down_read         >> set_graph_notrace
echo up_read           >> set_graph_notrace
echo down_write        >> set_graph_notrace
echo up_write          >> set_graph_notrace
echo down_write_trylock >> set_graph_notrace

# 调度与等待
echo schedule          >> set_graph_notrace
echo io_schedule       >> set_graph_notrace
echo schedule_timeout  >> set_graph_notrace
echo __wake_up         >> set_graph_notrace
echo finish_wait       >> set_graph_notrace
echo add_wait_queue    >> set_graph_notrace
echo remove_wait_queue >> set_graph_notrace

# RCU
echo rcu_all_qs        >> set_graph_notrace
echo rcu_note_context_switch >> set_graph_notrace

# 时间与 atime 更新
echo ktime_get              >> set_graph_notrace
echo ktime_get_coarse_real_ts64 >> set_graph_notrace
echo ktime_get_real_seconds >> set_graph_notrace
echo arch_counter_read      >> set_graph_notrace
echo current_time           >> set_graph_notrace
echo timestamp_truncate     >> set_graph_notrace
echo touch_atime            >> set_graph_notrace
echo atime_needs_update     >> set_graph_notrace
echo generic_update_time    >> set_graph_notrace
echo file_update_time       >> set_graph_notrace

# 文件系统通知
echo __fsnotify_parent >> set_graph_notrace
echo fsnotify          >> set_graph_notrace

# 安全模块
echo security_file_permission >> set_graph_notrace

# 调试辅助函数（你内核里的 update_maxtrace）
echo update_maxtrace   >> set_graph_notrace

# 串口 / TTY 驱动（噪声源）
echo uart_write        >> set_graph_notrace
echo uart_start        >> set_graph_notrace
echo __uart_start      >> set_graph_notrace
echo pl011_start_tx    >> set_graph_notrace
echo pl011_start_tx_pio >> set_graph_notrace
echo pl011_tx_chars    >> set_graph_notrace
echo pl011_tx_char     >> set_graph_notrace
echo pl011_read        >> set_graph_notrace
echo pl011_stop_tx     >> set_graph_notrace
echo redirected_tty_write >> set_graph_notrace
echo uart_write_room   >> set_graph_notrace
echo uart_flush_chars  >> set_graph_notrace
echo ldsem_down_read   >> set_graph_notrace
echo ldsem_up_read     >> set_graph_notrace
echo process_echoes    >> set_graph_notrace
echo "tty_*" >> set_graph_notrace
echo "n_tty_*" >> set_graph_notrace

# 如果你还看到其他不想看的内核线程函数，可以继续添加

# 7. 关闭块层事件，避免 trace 中插入 bio 事件文本
# [ -f events/block/block_bio_queue/enable ] && echo 0 > events/block/block_bio_queue/enable

# 8. 刷新缓存，确保冷读
echo 3 > /proc/sys/vm/drop_caches

# 9. 开启追踪 → 运行测试 → 关闭追踪
echo 1 > tracing_on
taskset -c 16 dd if=/mnt/mmc/zerofile of=/mnt/mmc/zerofile2 bs=1k count=8 2>/dev/null
taskset -c 16 dd if=/mnt/mmc/zerofile of=/mnt/mmc/zerofile2 bs=1k count=8 2>/dev/null
echo 0 > tracing_on

# 10. 显示结果
cat trace
```

## 参考
[linux-5.4.74](https://elixir.bootlin.com/linux/v5.4.74/source)  
[trace-pagecache-rw-fault-mmap](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/trace-pagecache-rw-fault-mmap.txt)  
[trace-vfs-do_writepages](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/trace-vfs-do_writepages.txt)