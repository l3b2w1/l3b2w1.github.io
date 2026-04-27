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
# dd if=/mnt/mmc/zerofile of=/mnt/mmc/zerofile2
```

## 日志分析
#### ext4 读路径分析（冷读触发预读）
trace 显示 ext4_file_read_iter 被调用，是从 ext4 文件冷读时的标准调用链。关键路径如下：
```
vfs_read()
  rw_verify_area()
  __vfs_read()
    new_sync_read()
      ext4_file_read_iter()
        generic_file_read_iter()
          pagecache_get_page.part.65()
            find_lock_entry()
              find_get_entry()
                PageHuge()
            page_mapping()
            mark_page_accessed()
          page_cache_sync_readahead()       # 同步预读
            ondemand_readahead()
              __do_page_cache_readahead()
                __page_cache_alloc()        # 分配新页
                read_pages()
                  ext4_readpages()
                    ext4_mpage_readpages()
                      add_to_page_cache_lru() # 加入 page cache
                      ext4_map_blocks()       # 逻辑块→物理块映射
                      bio_alloc_bioset()      # 申请 bio
                      bio_associate_blkg()    # 关联 cgroup
                      bio_add_page()          # 填充 bio
                      submit_bio()            # 提交 bio 到块层
                        generic_make_request()
                          generic_make_request_checks()
                          blk_mq_make_request() # 进入多队列块层
                            __blk_mq_sched_bio_merge()
                            blk_mq_get_request()
                            blk_account_io_start()
                            blk_add_rq_to_plug()  # plug 队列延迟派发
                      put_pages_list()
                      blk_finish_plug()
                        blk_flush_plug_list()
                          blk_mq_flush_plug_list()
                            blk_mq_sched_insert_requests()
                              dd_insert_requests() # deadline 调度器
                                blk_mq_run_hw_queue() # 唤醒硬件队列
                                  __blk_mq_delay_run_hw_queue()
                                    kblockd_mod_delayed_work_on() # workqueue 异步触发
          touch_atime()
          __mark_inode_dirty()
```
关键点：  
	1. 冷读触发预读：page_cache_sync_readahead() 一次性分配多个页并通过 ext4_readpages 批量读取。  
	2. 块层提交：submit_bio → generic_make_request → blk_mq_make_request，  
     配合 blk_add_rq_to_plug 和 blk_finish_plug 使用 plug 机制优化 I/O。  
	3. 驱动层未出现：blk_mq_run_hw_queue 后续由 workqueue 异步触发，  
     实际 eMMC 驱动函数（如 mmc_mq_queue_rq）不在 vfs_read 调用链内。

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
        generic_write_check_limits()
        __generic_file_write_iter()
          file_remove_privs()
          generic_perform_write()
            ext4_da_write_begin()                 # 延迟分配写开始
              grab_cache_page_write_begin()       # 查找/分配页
              __ext4_journal_start_sb()           # 开启日志事务
              __block_write_begin()               # 准备缓冲区
                ext4_da_get_block_prep()          # 预留磁盘块
                  ext4_es_insert_delayed_block()  # 插入延迟分配记录
            ext4_da_write_end()
              generic_write_end()
                block_write_end()
                  __block_commit_write()          # 标记缓冲区为脏
                    mark_buffer_dirty()           # → buffer_head 脏
                      __mark_inode_dirty()        # → inode 脏，触发日志
                __ext4_journal_stop()             # 日志事务结束
            balance_dirty_pages_ratelimited()
  __sb_end_write()
```

写路径没有 submit_bio 的原因：  
1. ext4 使用 延迟分配策略：写入只标记页脏并记录日志，不立即下发 I/O。  
2. 真正 I/O 由后台 writeback 线程异步完成，不在 vfs_write 系统调用链上。  
3. 若要观察写入的实际块层 I/O，应追踪 ext4_writepages 或 do_writepages。  

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2026-04-27-vfs-write.png)

## 跟踪脚本
```
#!/bin/sh

TRACING_DIR=/sys/kernel/debug/tracing

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

# 4. 只允许 vfs_read 和 vfs_write 作为“根函数”展开调用图
echo vfs_read  >> set_graph_function
echo vfs_write >> set_graph_function

# 5. 配置图形输出选项，减少干扰
echo 0 > options/funcgraph-irqs       # 不显示中断处理函数
echo 0 > options/funcgraph-proc       # 不显示进程名（可选）
echo 16 > max_graph_depth             # 限制深度，避免刷屏

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
echo tty_write         >> set_graph_notrace
echo tty_write_room    >> set_graph_notrace
echo tty_hung_up_p     >> set_graph_notrace
echo n_tty_write       >> set_graph_notrace
echo redirected_tty_write >> set_graph_notrace
echo uart_write_room   >> set_graph_notrace
echo uart_flush_chars  >> set_graph_notrace
echo tty_ldisc_ref_wait >> set_graph_notrace
echo tty_ldisc_deref   >> set_graph_notrace
echo ldsem_down_read   >> set_graph_notrace
echo ldsem_up_read     >> set_graph_notrace
echo process_echoes    >> set_graph_notrace
echo tty_port_default_wakeup >> set_graph_notrace
echo tty_wakeup        >> set_graph_notrace

# 如果你还看到其他不想看的内核线程函数，可以继续添加

# 7. 关闭块层事件，避免 trace 中插入 bio 事件文本
# [ -f events/block/block_bio_queue/enable ] && echo 0 > events/block/block_bio_queue/enable

# 8. 刷新缓存，确保冷读
echo 3 > /proc/sys/vm/drop_caches

# 9. 开启追踪 → 运行测试 → 关闭追踪
echo 1 > tracing_on
dd if=/mnt/mmc/zerofile of=/mnt/mmc/zerofile2 bs=1k count=4 2>/dev/null
echo 0 > tracing_on

# 10. 显示结果
cat trace
```

## 参考
[linux-5.4.74](https://elixir.bootlin.com/linux/v5.4.74/source)
