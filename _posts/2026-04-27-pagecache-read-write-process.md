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
echo 1 > options/funcgraph-tail       # 显示函数结尾

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

# 完整log
```
#
#
# /trace-vfs-read.sh
sh: write error: Invalid argument
[   64.160200] trace-vfs-read. (3318): drop_caches: 3
# tracer: function_graph
#
# CPU  DURATION                  FUNCTION CALLS
# |     |   |                     |   |   |   |
 20)               |  vfs_write() {
 20)   2.570 us    |    rw_verify_area();
 20)   1.950 us    |    __sb_start_write();
 20)               |    __vfs_write() {
 20)               |      new_sync_write() {
 20)               |        generic_file_write_iter() {
 20)   2.000 us    |          generic_write_check_limits.isra.58();
 20)               |          __generic_file_write_iter() {
 20)   1.990 us    |            file_remove_privs();
 20)               |            generic_perform_write() {
 20)               |              shmem_write_begin() {
 20)               |                shmem_getpage_gfp.isra.56() {
 20)               |                  find_lock_entry() {
 20)               |                    find_get_entry() {
 20)   2.040 us    |                      PageHuge();
 20)   6.560 us    |                    }
 20)   1.910 us    |                    page_mapping();
 20) + 14.320 us   |                  }
 20)   1.910 us    |                  mark_page_accessed();
 20) + 22.050 us   |                }
 20) + 25.990 us   |              }
 20)   1.850 us    |              flush_dcache_page();
 20)               |              shmem_write_end() {
 20)               |                set_page_dirty() {
 20)   1.940 us    |                  page_mapping();
 20)   1.950 us    |                  __set_page_dirty_no_writeback();
 20)   9.540 us    |                }
 20)   1.980 us    |                unlock_page();
 20) + 17.240 us   |              }
 20)   2.390 us    |              _cond_resched();
 20)   1.950 us    |              balance_dirty_pages_ratelimited();
 20) + 61.910 us   |            }
 20) + 71.150 us   |          }
 20) + 80.000 us   |        }
 20) + 84.180 us   |      }
 20) + 87.900 us   |    }
 20)   1.910 us    |    __sb_end_write();
 20) ! 107.020 us  |  }
 20)               |  vfs_read() {
 20)   2.700 us    |    rw_verify_area();
 20)               |    __vfs_read() {
 20)               |      new_sync_read() {
 20)               |        sock_read_iter() {
 20)               |          unix_dgram_recvmsg() {
 20)               |            __skb_try_recv_datagram() {
 20)   1.060 us    |              __skb_try_recv_from_queue();
 20)   5.400 us    |            }
 20)               |            __skb_wait_for_more_packets() {
 20)   3.220 us    |              prepare_to_wait_exclusive();
 21)               |  vfs_read() {
 21)   2.920 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        shmem_file_read_iter() {
 21)               |          shmem_getpage_gfp.isra.56() {
 21)               |            find_lock_entry() {
 21)               |              find_get_entry() {
 21)   1.830 us    |                PageHuge();
 21)   5.790 us    |              }
 21)   2.240 us    |              page_mapping();
 21) + 13.920 us   |            }
 21) + 17.770 us   |          }
 21)               |          set_page_dirty() {
 21)   1.830 us    |            page_mapping();
 21)   1.830 us    |            __set_page_dirty_no_writeback();
 21)   9.190 us    |          }
 21)   1.920 us    |          unlock_page();
 21)   1.850 us    |          mark_page_accessed();
 21) + 43.590 us   |        }
 21) + 47.500 us   |      }
 21) + 51.250 us   |    }
 21) + 62.480 us   |  }
 21)               |  vfs_read() {
 21)   2.670 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        shmem_file_read_iter() {
 21)               |          shmem_getpage_gfp.isra.56() {
 21)               |            find_lock_entry() {
 21)               |              find_get_entry() {
 21)   1.840 us    |                PageHuge();
 21)   5.670 us    |              }
 21)   1.820 us    |              page_mapping();
 21) + 13.120 us   |            }
 21) + 17.060 us   |          }
 21)               |          set_page_dirty() {
 21)   1.880 us    |            page_mapping();
 21)   1.860 us    |            __set_page_dirty_no_writeback();
 21)   9.340 us    |          }
 21)   1.920 us    |          unlock_page();
 21) + 37.300 us   |        }
 21) + 41.100 us   |      }
 21) + 44.800 us   |    }
 21) + 54.150 us   |  }
 21)               |  vfs_read() {
 21)   2.270 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        shmem_file_read_iter() {
 21)               |          shmem_getpage_gfp.isra.56() {
 21)               |            find_lock_entry() {
 21)               |              find_get_entry() {
 21)   1.760 us    |                PageHuge();
 21)   5.540 us    |              }
 21)   1.820 us    |              page_mapping();
 21) + 12.900 us   |            }
 21) + 16.620 us   |          }
 21)               |          set_page_dirty() {
 21)   1.840 us    |            page_mapping();
 21)   1.840 us    |            __set_page_dirty_no_writeback();
 21)   9.130 us    |          }
 21)   1.910 us    |          unlock_page();
 21) + 35.800 us   |        }
 21) + 39.480 us   |      }
 21) + 43.050 us   |    }
 21) + 51.230 us   |  }
 21)               |  vfs_read() {
 21)   2.470 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        shmem_file_read_iter() {
 21)               |          shmem_getpage_gfp.isra.56() {
 21)               |            find_lock_entry() {
 21)               |              find_get_entry() {
 21)   1.900 us    |                PageHuge();
 21)   5.940 us    |              }
 21)   1.880 us    |              page_mapping();
 21) + 13.470 us   |            }
 21) + 17.140 us   |          }
 21)               |          set_page_dirty() {
 21)   1.830 us    |            page_mapping();
 21)   1.840 us    |            __set_page_dirty_no_writeback();
 21)   9.240 us    |          }
 21)   1.900 us    |          unlock_page();
 21)   1.820 us    |          mark_page_accessed();
 21) + 42.120 us   |        }
 21) + 45.820 us   |      }
 21) + 50.810 us   |    }
 21) + 59.840 us   |  }
 21)               |  vfs_read() {
 21)   2.330 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        shmem_file_read_iter() {
 21)               |          shmem_getpage_gfp.isra.56() {
 21)               |            find_lock_entry() {
 21)               |              find_get_entry() {
 21)   1.830 us    |                PageHuge();
 21)   5.520 us    |              }
 21)   1.810 us    |              page_mapping();
 21) + 12.940 us   |            }
 21) + 16.620 us   |          }
 21)               |          set_page_dirty() {
 21)   1.800 us    |            page_mapping();
 21)   1.820 us    |            __set_page_dirty_no_writeback();
 21)   9.110 us    |          }
 21)   1.930 us    |          unlock_page();
 21) + 36.070 us   |        }
 21) + 39.780 us   |      }
 21) + 43.430 us   |    }
 21) + 51.670 us   |  }
 21)               |  vfs_read() {
 21)   2.550 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        shmem_file_read_iter() {
 21)               |          shmem_getpage_gfp.isra.56() {
 21)               |            find_lock_entry() {
 21)               |              find_get_entry() {
 21)   1.970 us    |                PageHuge();
 21)   6.140 us    |              }
 21)   1.900 us    |              page_mapping();
 21) + 13.810 us   |            }
 21) + 17.710 us   |          }
 21)   1.950 us    |          unlock_page();
 21)   1.850 us    |          mark_page_accessed();
 21) + 89.460 us   |        }
 21) + 93.380 us   |      }
 21) + 97.080 us   |    }
 21) ! 107.000 us  |  }
 21)               |  vfs_read() {
 21)   2.620 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        shmem_file_read_iter() {
 21)               |          shmem_getpage_gfp.isra.56() {
 21)               |            find_lock_entry() {
 21)               |              find_get_entry() {
 21)   1.950 us    |                PageHuge();
 21)   6.260 us    |              }
 21)   1.990 us    |              page_mapping();
 21) + 13.930 us   |            }
 21) + 18.170 us   |          }
 21)   1.960 us    |          unlock_page();
 21)   1.870 us    |          mark_page_accessed();
 21) + 32.810 us   |        }
 21) + 36.650 us   |      }
 21) + 40.410 us   |    }
 21) + 49.860 us   |  }
 21)               |  vfs_read() {
 21)   2.830 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        ext4_file_read_iter() {
 21)               |          generic_file_read_iter() {
 21)   2.270 us    |            _cond_resched();
 21)               |            pagecache_get_page.part.65() {
 21)   1.970 us    |              find_get_entry();
 21)   5.860 us    |            }
 21)               |            page_cache_sync_readahead() {
 21)   1.890 us    |              kthread_blkcg();
 21)               |              ondemand_readahead() {
 21)               |                __do_page_cache_readahead() {
 21)               |                  __page_cache_alloc() {
 21)               |                    alloc_pages_current() {
 21)   2.000 us    |                      get_task_policy.part.48();
 21)   1.880 us    |                      policy_node();
 21)   1.870 us    |                      policy_nodemask();
 21)               |                      __alloc_pages_nodemask() {
 21)   1.970 us    |                        should_fail_alloc_page();
 21)               |                        get_page_from_freelist.part.112() {
 21)   0.980 us    |                          __inc_numa_state();
 21)   0.970 us    |                          __inc_numa_state();
 21)   1.950 us    |                          prep_new_page();
 21) + 10.820 us   |                        }
 21) + 18.580 us   |                      }
 21) + 33.760 us   |                    }
 21) + 37.570 us   |                  }
 21)               |                  read_pages() {
 21)   1.810 us    |                    blk_start_plug();
 21)               |                    ext4_readpages() {
 21)               |                      ext4_mpage_readpages() {
 21)               |                        add_to_page_cache_lru() {
 21)               |                          __add_to_page_cache_locked() {
 21)   1.850 us    |                            PageHuge();
 21)   1.900 us    |                            shmem_mapping();
 21)               |                            mem_cgroup_try_charge() {
 21)   2.030 us    |                              get_mem_cgroup_from_mm.part.47();
 21)   1.870 us    |                              try_charge();
 21)   9.470 us    |                            }
 21)               |                            __inc_node_page_state() {
 21)   0.970 us    |                              __inc_node_state();
 21)   2.860 us    |                            }
 21)               |                            mem_cgroup_commit_charge() {
 21)               |                              mem_cgroup_charge_statistics() {
 21)   1.040 us    |                                __mod_memcg_state();
 21)   1.070 us    |                                __count_memcg_events();
 21)   5.120 us    |                              }
 21)               |                              memcg_check_events() {
 21)   1.050 us    |                                mem_cgroup_event_ratelimit.isra.38();
 21)   2.930 us    |                              }
 21) + 12.960 us   |                            }
 21) + 40.750 us   |                          }
 21)               |                          lru_cache_add() {
 21)   1.940 us    |                            __lru_cache_add();
 21)   5.620 us    |                          }
 21) + 52.030 us   |                        }
 21)               |                        ext4_map_blocks() {
 21)   2.270 us    |                          ext4_es_lookup_extent();
 21)               |                          ext4_ind_map_blocks() {
 21)   1.970 us    |                            ext4_block_to_path.isra.9();
 21)   1.830 us    |                            ext4_get_branch();
 21)   9.720 us    |                          }
 21)               |                          ext4_es_insert_extent() {
 21)               |                            __es_remove_extent() {
 21)   1.840 us    |                              __es_tree_search.isra.18();
 21)   5.600 us    |                            }
 21)               |                            __es_insert_extent() {
 21)               |                              kmem_cache_alloc() {
 21)   1.850 us    |                                should_failslab();
 21)   1.870 us    |                                set_tag();
 21)   1.920 us    |                                do_track();
 21) + 13.370 us   |                              }
 21) + 17.600 us   |                            }
 21) + 28.970 us   |                          }
 21)               |                          __check_block_validity.constprop.90() {
 21)               |                            ext4_data_block_valid() {
 21)   2.200 us    |                              ext4_data_block_valid_rcu.isra.6();
 21)   5.910 us    |                            }
 21)   9.700 us    |                          }
 21) + 61.100 us   |                        }
 21)               |                        bio_alloc_bioset() {
 21)               |                          mempool_alloc() {
 21)               |                            mempool_alloc_slab() {
 21)               |                              kmem_cache_alloc() {
 21)   1.850 us    |                                should_failslab();
 21)   1.850 us    |                                set_tag();
 21)   1.890 us    |                                do_track();
 21) + 13.120 us   |                              }
 21) + 17.970 us   |                            }
 21) + 21.770 us   |                          }
 21) + 25.690 us   |                        }
 21)               |                        bio_associate_blkg() {
 21)   1.950 us    |                          kthread_blkcg();
 21)               |                          bio_associate_blkg_from_css() {
 21)   1.980 us    |                            __bio_associate_blkg.isra.35();
 21)   5.740 us    |                          }
 21) + 13.260 us   |                        }
 21)               |                        bio_add_page() {
 21)   1.940 us    |                          __bio_try_merge_page();
 21)   1.920 us    |                          __bio_add_page();
 21)   9.380 us    |                        }
 21)               |                        submit_bio() {
 21)               |                          generic_make_request() {
 21)               |                            generic_make_request_checks() {
 21)   1.860 us    |                              should_fail_bio.isra.55();
 21)   1.970 us    |                              __disk_get_part();
 21) + 10.580 us   |                            }
 21)   2.060 us    |                            blk_queue_enter();
 21)               |                            blk_mq_make_request() {
 21)   2.010 us    |                              __blk_queue_split();
 21)   1.940 us    |                              bio_integrity_prep();
 21)   1.980 us    |                              blk_attempt_plug_merge();
 21)               |                              __blk_mq_sched_bio_merge() {
 21)               |                                dd_bio_merge() {
 21)               |                                  blk_mq_sched_try_merge() {
 21)               |                                    elv_merge() {
 21)   1.980 us    |                                      elv_rqhash_find();
 21)               |                                      dd_request_merge() {
 21)   2.030 us    |                                        elv_rb_find();
 21)   5.830 us    |                                      }
 21) + 13.650 us   |                                    }
 21) + 17.410 us   |                                  }
 21) + 21.360 us   |                                }
 21) + 25.140 us   |                              }
 21)               |                              blk_mq_get_request() {
 21)               |                                blk_mq_get_tag() {
 21)   2.210 us    |                                  __blk_mq_get_tag();
 21)   5.990 us    |                                }
 21)   1.930 us    |                                dd_prepare_request();
 21) + 14.460 us   |                              }
 21)               |                              blk_account_io_start() {
 21)   1.870 us    |                                disk_map_sector_rcu();
 21)   1.850 us    |                                part_inc_in_flight();
 21)               |                                update_io_ticks() {
 21) + 56.970 us   |                                }
 21) + 68.260 us   |                              }
 21)   2.120 us    |                              blk_add_rq_to_plug();
 21) ! 130.950 us  |                            }
 21) ! 151.230 us  |                          }
 21) ! 155.030 us  |                        }
 21) ! 330.450 us  |                      }
 21) ! 334.300 us  |                    }
 21)   1.940 us    |                    put_pages_list();
 21)               |                    blk_finish_plug() {
 21)               |                      blk_flush_plug_list() {
 21)               |                        blk_mq_flush_plug_list() {
 21)               |                          blk_mq_sched_insert_requests() {
 21)               |                            dd_insert_requests() {
 21)               |                              blk_mq_sched_try_insert_merge() {
 21)               |                                elv_attempt_insert_merge() {
 21)   1.960 us    |                                  elv_rqhash_find();
 21)   5.710 us    |                                }
 21) + 10.650 us   |                              }
 21)   1.860 us    |                              blk_mq_sched_request_inserted();
 21)   1.990 us    |                              elv_rb_add();
 21)   1.930 us    |                              elv_rqhash_add();
 21) + 25.940 us   |                            }
 21)               |                            blk_mq_run_hw_queue() {
 21)   2.090 us    |                              __srcu_read_lock();
 21)   1.840 us    |                              dd_has_work();
 21)   1.960 us    |                              __srcu_read_unlock();
 21)               |                              __blk_mq_delay_run_hw_queue() {
 21)   1.860 us    |                                __msecs_to_jiffies();
 21)               |                                kblockd_mod_delayed_work_on() {
 21)               |                                  mod_delayed_work_on() {
 21)               |                                    try_to_grab_pending() {
 21)   1.000 us    |                                      del_timer();
 21)   4.380 us    |                                    }
 21)               |                                    __queue_delayed_work() {
 21)               |                                      __queue_work() {
 21)   1.140 us    |                                        get_work_pool();
 21)               |                                        insert_work() {
 21)   0.970 us    |                                          get_pwq.isra.30();
 21)               |                                          wake_up_process() {
 21)               |                                            try_to_wake_up() {
 21)   1.060 us    |                                              update_rq_clock.part.108();
 21)               |                                              ttwu_do_activate.isra.113() {
 21)               |                                                activate_task() {
 21)               |                                                  enqueue_task_fair() {
 21)               |                                                    enqueue_entity() {
 21)               |                                                      update_curr() {
 21)   0.980 us    |                                                        update_min_vruntime();
 21)               |                                                        cpuacct_charge() {
 21)               |                                                          need_beauty_cputime() {
 21)   0.960 us    |                                                            beauty_cpu_usage_ctrl_update();
 21)   2.830 us    |                                                          }
 21)   4.820 us    |                                                        }
 21)   8.800 us    |                                                      }
 21)               |                                                      __update_load_avg_se() {
 21)   0.940 us    |                                                        __accumulate_pelt_segments();
 21)   3.090 us    |                                                      }
 21)               |                                                      __update_load_avg_cfs_rq() {
 21)   0.950 us    |                                                        __accumulate_pelt_segments();
 21)   2.950 us    |                                                      }
 21)   0.920 us    |                                                      update_cfs_group();
 21)   1.010 us    |                                                      account_entity_enqueue();
 21)   0.990 us    |                                                      __enqueue_entity();
 21) + 24.440 us   |                                                    }
 21) + 26.550 us   |                                                  }
 21) + 28.580 us   |                                                }
 21)               |                                                ttwu_do_wakeup.isra.112() {
 21)               |                                                  check_preempt_curr() {
 21)               |                                                    check_preempt_wakeup() {
 21)   0.990 us    |                                                      update_curr();
 21)               |                                                      wakeup_preempt_entity.isra.98() {
 21)   1.000 us    |                                                        __calc_delta();
 21)   2.940 us    |                                                      }
 21)   1.000 us    |                                                      resched_curr();
 21)   8.760 us    |                                                    }
 21) + 10.790 us   |                                                  }
 21) + 13.350 us   |                                                }
 21) + 44.840 us   |                                              }
 21) + 49.270 us   |                                            }
 21) + 51.160 us   |                                          }
 21) + 55.060 us   |                                        }
 21) + 59.440 us   |                                      }
 21) + 61.440 us   |                                    }
 21) + 70.360 us   |                                  }
 21) + 74.160 us   |                                }
 21) + 81.530 us   |                              }
 21) + 96.700 us   |                            }
 21) ! 128.350 us  |                          }
 21) ! 132.200 us  |                        }
 21) ! 135.910 us  |                      }
 21) ! 139.620 us  |                    }
 21) ! 487.340 us  |                  }
 21) ! 530.860 us  |                }
 21) ! 534.870 us  |              }
 21) ! 542.740 us  |            }
 21)               |            pagecache_get_page.part.65() {
 21)               |              find_get_entry() {
 21)   1.900 us    |                PageHuge();
 21)   5.880 us    |              }
 21)   9.700 us    |            }
 21)   2.570 us    |            mark_page_accessed();
 21) ! 929.360 us  |          }
 21) ! 933.410 us  |        }
 21) ! 938.800 us  |      }
 21) ! 943.550 us  |    }
 21) ! 953.720 us  |  }
 21)               |  vfs_write() {
 21)   2.270 us    |    rw_verify_area();
 21)   2.210 us    |    __sb_start_write();
 21)               |    __vfs_write() {
 21)               |      new_sync_write() {
 21)               |        ext4_file_write_iter() {
 21)   1.920 us    |          generic_write_check_limits.isra.58();
 21)               |          __generic_file_write_iter() {
 21)               |            file_remove_privs() {
 21)               |              dentry_needs_remove_privs.part.34() {
 21)   1.910 us    |                should_remove_suid();
 21)               |                security_inode_need_killpriv() {
 21)               |                  cap_inode_need_killpriv() {
 21)               |                    __vfs_getxattr() {
 21)   2.170 us    |                      xattr_resolve_name();
 21)   5.960 us    |                    }
 21)   9.780 us    |                  }
 21) + 13.620 us   |                }
 21) + 21.140 us   |              }
 21) + 24.990 us   |            }
 21)               |            generic_perform_write() {
 21)               |              ext4_da_write_begin() {
 21)   1.950 us    |                ext4_nonda_switch();
 21)               |                grab_cache_page_write_begin() {
 21)               |                  pagecache_get_page.part.65() {
 21)   2.080 us    |                    find_get_entry();
 21)               |                    __page_cache_alloc() {
 21)               |                      alloc_pages_current() {
 21)   2.000 us    |                        get_task_policy.part.48();
 21)   1.830 us    |                        policy_node();
 21)   1.850 us    |                        policy_nodemask();
 21)               |                        __alloc_pages_nodemask() {
 21)   1.920 us    |                          should_fail_alloc_page();
 21)               |                          get_page_from_freelist.part.112() {
 21)               |                            node_dirty_ok() {
 21)   1.980 us    |                              node_page_state();
 21)   1.860 us    |                              node_page_state();
 21)   1.900 us    |                              node_page_state();
 21)   1.820 us    |                              node_page_state();
 21)   1.890 us    |                              node_page_state();
 21) + 20.640 us   |                            }
 21)   1.020 us    |                            __inc_numa_state();
 21)   0.970 us    |                            __inc_numa_state();
 21)   1.950 us    |                            prep_new_page();
 21) + 33.490 us   |                          }
 21) + 41.150 us   |                        }
 21) + 56.090 us   |                      }
 21) + 59.880 us   |                    }
 21)               |                    add_to_page_cache_lru() {
 21)               |                      __add_to_page_cache_locked() {
 21)   1.840 us    |                        PageHuge();
 21)   1.960 us    |                        shmem_mapping();
 21)               |                        mem_cgroup_try_charge() {
 21)   2.000 us    |                          get_mem_cgroup_from_mm.part.47();
 21)   1.890 us    |                          try_charge();
 21)   9.610 us    |                        }
 21)               |                        __inc_node_page_state() {
 21)   0.960 us    |                          __inc_node_state();
 21)   2.840 us    |                        }
 21)               |                        mem_cgroup_commit_charge() {
 21)               |                          mem_cgroup_charge_statistics() {
 21)   1.060 us    |                            __mod_memcg_state();
 21)   1.040 us    |                            __count_memcg_events();
 21)   4.980 us    |                          }
 21)               |                          memcg_check_events() {
 21)   1.060 us    |                            mem_cgroup_event_ratelimit.isra.38();
 21)   2.920 us    |                          }
 21) + 12.770 us   |                        }
 21) + 41.060 us   |                      }
 21)               |                      lru_cache_add() {
 21)   1.930 us    |                        __lru_cache_add();
 21)   5.720 us    |                      }
 21) + 52.480 us   |                    }
 21) ! 122.080 us  |                  }
 21)   1.850 us    |                  wait_for_stable_page();
 21) ! 129.810 us  |                }
 21)   1.920 us    |                unlock_page();
 21)               |                __ext4_journal_start_sb() {
 21)   1.910 us    |                  ext4_journal_check_start();
 21)   5.800 us    |                }
 21)   1.900 us    |                wait_for_stable_page();
 21)               |                __block_write_begin() {
 21)               |                  __block_write_begin_int() {
 21)               |                    create_page_buffers() {
 21)               |                      create_empty_buffers() {
 21)               |                        alloc_page_buffers() {
 21)   1.830 us    |                          get_mem_cgroup_from_page();
 21)               |                          alloc_buffer_head() {
 21)               |                            kmem_cache_alloc() {
 21)   1.870 us    |                              should_failslab();
 21)   1.860 us    |                              set_tag();
 21)   1.850 us    |                              do_track();
 21) + 13.570 us   |                            }
 21)   1.970 us    |                            recalc_bh_state();
 21) + 21.290 us   |                          }
 21) + 28.730 us   |                        }
 21) + 32.720 us   |                      }
 21) + 36.480 us   |                    }
 21)               |                    ext4_da_get_block_prep() {
 21)   2.280 us    |                      ext4_es_lookup_extent();
 21)               |                      ext4_ind_map_blocks() {
 21)   1.880 us    |                        ext4_block_to_path.isra.9();
 21)   1.920 us    |                        ext4_get_branch();
 21)   9.560 us    |                      }
 21)               |                      ext4_da_reserve_space() {
 21)               |                        __dquot_alloc_space() {
 21)               |                          inode_reserved_space() {
 21)   1.850 us    |                            ext4_get_reserved_space();
 21)   5.670 us    |                          }
 21)   9.640 us    |                        }
 21)               |                        ext4_claim_free_clusters() {
 21)   1.930 us    |                          ext4_has_free_clusters();
 21)   5.820 us    |                        }
 21) + 21.460 us   |                      }
 21)               |                      ext4_es_insert_delayed_block() {
 21)               |                        __es_remove_extent() {
 21)   1.920 us    |                          __es_tree_search.isra.18();
 21)   5.730 us    |                        }
 21)               |                        __es_insert_extent() {
 21)               |                          kmem_cache_alloc() {
 21)   1.870 us    |                            should_failslab();
 21)   1.830 us    |                            set_tag();
 21)   1.830 us    |                            do_track();
 21) + 13.130 us   |                          }
 21) + 16.980 us   |                        }
 21) + 28.620 us   |                      }
 21) + 72.640 us   |                    }
 21)               |                    clean_bdev_aliases() {
 21)               |                      pagevec_lookup_range() {
 21)   2.150 us    |                        find_get_pages_range();
 21)   5.960 us    |                      }
 21)   10.000 us   |                    }
 21)   1.850 us    |                    flush_dcache_page();
 21) ! 131.240 us  |                  }
 21) ! 135.100 us  |                }
 21) ! 291.260 us  |              }
 21)   1.870 us    |              flush_dcache_page();
 21)               |              ext4_da_write_end() {
 21)               |                generic_write_end() {
 21)               |                  block_write_end() {
 21)   1.820 us    |                    flush_dcache_page();
 21)               |                    __block_commit_write.isra.41() {
 21)               |                      mark_buffer_dirty() {
 21)               |                        lock_page_memcg() {
 21)   1.830 us    |                          lock_page_memcg.part.52();
 21)   5.680 us    |                        }
 21)   1.900 us    |                        page_mapping();
 21)               |                        __set_page_dirty() {
 21)               |                          account_page_dirtied() {
 21)               |                            __mod_lruvec_state() {
 21)   1.020 us    |                              __mod_node_page_state();
 21)   1.040 us    |                              __mod_memcg_state();
 21)   5.010 us    |                            }
 21)               |                            __inc_zone_page_state() {
 21)   1.060 us    |                              __inc_zone_state();
 21)   3.040 us    |                            }
 21)               |                            __inc_node_page_state() {
 21)   0.940 us    |                              __inc_node_state();
 21)   2.820 us    |                            }
 21) + 15.150 us   |                          }
 21) ! 106.210 us  |                        }
 21)               |                        unlock_page_memcg() {
 21)   1.830 us    |                          __unlock_page_memcg();
 21)   5.610 us    |                        }
 21)   1.970 us    |                        __mark_inode_dirty();
 21) ! 132.980 us  |                      }
 21) ! 137.140 us  |                    }
 21) ! 144.570 us  |                  }
 21)   1.970 us    |                  unlock_page();
 21)               |                  __mark_inode_dirty() {
 21)               |                    ext4_dirty_inode() {
 21)               |                      __ext4_journal_start_sb() {
 21)   1.930 us    |                        ext4_journal_check_start();
 21)   5.850 us    |                      }
 21)               |                      ext4_mark_inode_dirty() {
 21)               |                        ext4_reserve_inode_write() {
 21)               |                          __ext4_get_inode_loc() {
 21)   2.030 us    |                            ext4_get_group_desc();
 21)   1.930 us    |                            ext4_inode_table();
 21)               |                            __getblk_gfp() {
 21)               |                              __find_get_block() {
 21)   2.020 us    |                                mark_page_accessed();
 21)   7.140 us    |                              }
 21) + 10.850 us   |                            }
 21) + 22.610 us   |                          }
 21)   1.930 us    |                          __ext4_journal_get_write_access();
 21) + 30.370 us   |                        }
 21)               |                        ext4_mark_iloc_dirty() {
 21)               |                          from_kuid() {
 21)   1.910 us    |                            map_id_up();
 21)   5.640 us    |                          }
 21)               |                          from_kgid() {
 21)   1.860 us    |                            map_id_up();
 21)   5.670 us    |                          }
 21)               |                          from_kprojid() {
 21)   1.830 us    |                            map_id_up();
 21)   5.570 us    |                          }
 21)   1.860 us    |                          ext4_inode_csum_set();
 21)               |                          __ext4_handle_dirty_metadata() {
 21)   1.940 us    |                            mark_buffer_dirty();
 21)   5.670 us    |                          }
 21)   1.950 us    |                          __brelse();
 21) + 40.190 us   |                        }
 21) + 76.320 us   |                      }
 21)   1.890 us    |                      __ext4_journal_stop();
 21) + 91.600 us   |                    }
 21) + 95.500 us   |                  }
 21) ! 249.870 us  |                }
 21)   1.920 us    |                __ext4_journal_stop();
 21) ! 257.800 us  |              }
 21)   2.300 us    |              _cond_resched();
 21)   2.490 us    |              balance_dirty_pages_ratelimited();
 21) ! 568.380 us  |            }
 21) ! 607.760 us  |          }
 21) ! 616.660 us  |        }
 21) ! 620.930 us  |      }
 21) ! 624.610 us  |    }
 21)   1.960 us    |    __sb_end_write();
 21) ! 641.100 us  |  }
 21)               |  vfs_read() {
 21)   2.600 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        ext4_file_read_iter() {
 21)               |          generic_file_read_iter() {
 21)   2.110 us    |            _cond_resched();
 21)               |            pagecache_get_page.part.65() {
 21)               |              find_get_entry() {
 21)   1.840 us    |                PageHuge();
 21)   5.820 us    |              }
 21)   9.540 us    |            }
 21) + 18.740 us   |          }
 21) + 22.520 us   |        }
 21) + 26.360 us   |      }
 21) + 30.150 us   |    }
 21) + 38.740 us   |  }
 21)               |  vfs_write() {
 21)   2.060 us    |    rw_verify_area();
 21)   2.000 us    |    __sb_start_write();
 21)               |    __vfs_write() {
 21)               |      new_sync_write() {
 21)               |        ext4_file_write_iter() {
 21)   1.920 us    |          generic_write_check_limits.isra.58();
 21)               |          __generic_file_write_iter() {
 21)   1.900 us    |            file_remove_privs();
 21)               |            generic_perform_write() {
 21)               |              ext4_da_write_begin() {
 21)   1.920 us    |                ext4_nonda_switch();
 21)               |                grab_cache_page_write_begin() {
 21)               |                  pagecache_get_page.part.65() {
 21)               |                    find_get_entry() {
 21)   1.890 us    |                      PageHuge();
 21)   5.800 us    |                    }
 21)   9.660 us    |                  }
 21)   1.880 us    |                  wait_for_stable_page();
 21) + 17.240 us   |                }
 21)   1.940 us    |                unlock_page();
 21)               |                __ext4_journal_start_sb() {
 21)   1.890 us    |                  ext4_journal_check_start();
 21)   5.660 us    |                }
 21)   1.800 us    |                wait_for_stable_page();
 21)               |                __block_write_begin() {
 21)               |                  __block_write_begin_int() {
 21)   1.850 us    |                    create_page_buffers();
 21)   5.700 us    |                  }
 21)   9.450 us    |                }
 21) + 51.280 us   |              }
 21)   1.880 us    |              flush_dcache_page();
 21)               |              ext4_da_write_end() {
 21)               |                generic_write_end() {
 21)               |                  block_write_end() {
 21)   1.870 us    |                    flush_dcache_page();
 21)               |                    __block_commit_write.isra.41() {
 21)   1.900 us    |                      mark_buffer_dirty();
 21)   5.710 us    |                    }
 21) + 13.110 us   |                  }
 21)   1.940 us    |                  unlock_page();
 21)               |                  __mark_inode_dirty() {
 21)               |                    ext4_dirty_inode() {
 21)               |                      __ext4_journal_start_sb() {
 21)   1.900 us    |                        ext4_journal_check_start();
 21)   5.620 us    |                      }
 21)               |                      ext4_mark_inode_dirty() {
 21)               |                        ext4_reserve_inode_write() {
 21)               |                          __ext4_get_inode_loc() {
 21)   1.940 us    |                            ext4_get_group_desc();
 21)   1.840 us    |                            ext4_inode_table();
 21)               |                            __getblk_gfp() {
 21)               |                              __find_get_block() {
 21)   1.980 us    |                                mark_page_accessed();
 21)   6.780 us    |                              }
 21) + 10.390 us   |                            }
 21) + 21.490 us   |                          }
 21)   1.880 us    |                          __ext4_journal_get_write_access();
 21) + 28.910 us   |                        }
 21)               |                        ext4_mark_iloc_dirty() {
 21)               |                          from_kuid() {
 21)   1.990 us    |                            map_id_up();
 21)   5.680 us    |                          }
 21)               |                          from_kgid() {
 21)   1.870 us    |                            map_id_up();
 21)   5.540 us    |                          }
 21)               |                          from_kprojid() {
 21)   1.820 us    |                            map_id_up();
 21)   5.470 us    |                          }
 21)   1.840 us    |                          ext4_inode_csum_set();
 21)               |                          __ext4_handle_dirty_metadata() {
 21)   1.870 us    |                            mark_buffer_dirty();
 21)   5.510 us    |                          }
 21)   1.950 us    |                          __brelse();
 21) + 40.270 us   |                        }
 21) + 74.720 us   |                      }
 21)   1.870 us    |                      __ext4_journal_stop();
 21) + 89.560 us   |                    }
 21) + 93.270 us   |                  }
 21) ! 115.820 us  |                }
 21)   1.850 us    |                __ext4_journal_stop();
 21) ! 123.190 us  |              }
 21)   2.220 us    |              _cond_resched();
 21)   2.140 us    |              balance_dirty_pages_ratelimited();
 21) ! 192.360 us  |            }
 21) ! 206.630 us  |          }
 21) ! 214.950 us  |        }
 21) ! 218.920 us  |      }
 21) ! 222.640 us  |    }
 21)   1.890 us    |    __sb_end_write();
 21) ! 238.170 us  |  }
 21)               |  vfs_read() {
 21)   2.540 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        ext4_file_read_iter() {
 21)               |          generic_file_read_iter() {
 21)   2.070 us    |            _cond_resched();
 21)               |            pagecache_get_page.part.65() {
 21)               |              find_get_entry() {
 21)   1.830 us    |                PageHuge();
 21)   5.610 us    |              }
 21)   9.200 us    |            }
 21) + 17.900 us   |          }
 21) + 21.530 us   |        }
 21) + 25.240 us   |      }
 21) + 28.980 us   |    }
 21) + 37.340 us   |  }
 21)               |  vfs_write() {
 21)   2.040 us    |    rw_verify_area();
 21)   1.820 us    |    __sb_start_write();
 21)               |    __vfs_write() {
 21)               |      new_sync_write() {
 21)               |        ext4_file_write_iter() {
 21)   1.880 us    |          generic_write_check_limits.isra.58();
 21)               |          __generic_file_write_iter() {
 21)   1.870 us    |            file_remove_privs();
 21)               |            generic_perform_write() {
 21)               |              ext4_da_write_begin() {
 21)   1.930 us    |                ext4_nonda_switch();
 21)               |                grab_cache_page_write_begin() {
 21)               |                  pagecache_get_page.part.65() {
 21)               |                    find_get_entry() {
 21)   1.860 us    |                      PageHuge();
 21)   5.730 us    |                    }
 21)   9.520 us    |                  }
 21)   1.900 us    |                  wait_for_stable_page();
 21) + 16.960 us   |                }
 21)   1.920 us    |                unlock_page();
 21)               |                __ext4_journal_start_sb() {
 21)   1.860 us    |                  ext4_journal_check_start();
 21)   5.620 us    |                }
 21)   1.800 us    |                wait_for_stable_page();
 21)               |                __block_write_begin() {
 21)               |                  __block_write_begin_int() {
 21)   1.830 us    |                    create_page_buffers();
 21)   5.570 us    |                  }
 21)   9.180 us    |                }
 21) + 50.300 us   |              }
 21)   1.870 us    |              flush_dcache_page();
 21)               |              ext4_da_write_end() {
 21)               |                generic_write_end() {
 21)               |                  block_write_end() {
 21)   1.830 us    |                    flush_dcache_page();
 21)               |                    __block_commit_write.isra.41() {
 21)   1.920 us    |                      mark_buffer_dirty();
 21)   5.730 us    |                    }
 21) + 13.010 us   |                  }
 21)   1.960 us    |                  unlock_page();
 21)               |                  __mark_inode_dirty() {
 21)               |                    ext4_dirty_inode() {
 21)               |                      __ext4_journal_start_sb() {
 21)   1.860 us    |                        ext4_journal_check_start();
 21)   5.560 us    |                      }
 21)               |                      ext4_mark_inode_dirty() {
 21)               |                        ext4_reserve_inode_write() {
 21)               |                          __ext4_get_inode_loc() {
 21)   1.960 us    |                            ext4_get_group_desc();
 21)   1.850 us    |                            ext4_inode_table();
 21)               |                            __getblk_gfp() {
 21)               |                              __find_get_block() {
 21)   1.930 us    |                                mark_page_accessed();
 21)   6.780 us    |                              }
 21) + 10.430 us   |                            }
 21) + 21.660 us   |                          }
 21)   1.860 us    |                          __ext4_journal_get_write_access();
 21) + 29.020 us   |                        }
 21)               |                        ext4_mark_iloc_dirty() {
 21)               |                          from_kuid() {
 21)   1.860 us    |                            map_id_up();
 21)   5.570 us    |                          }
 21)               |                          from_kgid() {
 21)   1.870 us    |                            map_id_up();
 21)   5.530 us    |                          }
 21)               |                          from_kprojid() {
 21)   1.870 us    |                            map_id_up();
 21)   5.570 us    |                          }
 21)   1.820 us    |                          ext4_inode_csum_set();
 21)               |                          __ext4_handle_dirty_metadata() {
 21)   1.870 us    |                            mark_buffer_dirty();
 21)   5.580 us    |                          }
 21)   1.950 us    |                          __brelse();
 21) + 39.450 us   |                        }
 21) + 74.010 us   |                      }
 21)   1.910 us    |                      __ext4_journal_stop();
 21) + 89.710 us   |                    }
 21) + 93.490 us   |                  }
 21) ! 115.830 us  |                }
 21)   1.850 us    |                __ext4_journal_stop();
 21) ! 123.190 us  |              }
 21)   2.150 us    |              _cond_resched();
 21)   2.070 us    |              balance_dirty_pages_ratelimited();
 21) ! 190.660 us  |            }
 21) ! 198.700 us  |          }
 21) ! 206.720 us  |        }
 21) ! 210.570 us  |      }
 21) ! 214.220 us  |    }
 21)   1.880 us    |    __sb_end_write();
 21) ! 229.440 us  |  }
 21)               |  vfs_read() {
 21)   2.370 us    |    rw_verify_area();
 21)               |    __vfs_read() {
 21)               |      new_sync_read() {
 21)               |        ext4_file_read_iter() {
 21)               |          generic_file_read_iter() {
 21)   2.080 us    |            _cond_resched();
 21)               |            pagecache_get_page.part.65() {
 21)               |              find_get_entry() {
 21)   1.870 us    |                PageHuge();
 21)   5.700 us    |              }
 21)   9.350 us    |            }
 21) + 17.950 us   |          }
 21) + 21.610 us   |        }
 21) + 25.380 us   |      }
 21) + 29.090 us   |    }
 21) + 37.280 us   |  }
 21)               |  vfs_write() {
 21)   2.040 us    |    rw_verify_area();
 21)   1.840 us    |    __sb_start_write();
 21)               |    __vfs_write() {
 21)               |      new_sync_write() {
 21)               |        ext4_file_write_iter() {
 21)   1.930 us    |          generic_write_check_limits.isra.58();
 21)               |          __generic_file_write_iter() {
 21)   1.890 us    |            file_remove_privs();
 21)               |            generic_perform_write() {
 21)               |              ext4_da_write_begin() {
 21)   1.910 us    |                ext4_nonda_switch();
 21)               |                grab_cache_page_write_begin() {
 21)               |                  pagecache_get_page.part.65() {
 21)               |                    find_get_entry() {
 21)   1.870 us    |                      PageHuge();
 21)   5.690 us    |                    }
 21)   9.480 us    |                  }
 21)   1.890 us    |                  wait_for_stable_page();
 21) + 16.920 us   |                }
 21)   1.920 us    |                unlock_page();
 21)               |                __ext4_journal_start_sb() {
 21)   1.860 us    |                  ext4_journal_check_start();
 21)   5.720 us    |                }
 21)   1.840 us    |                wait_for_stable_page();
 21)               |                __block_write_begin() {
 21)               |                  __block_write_begin_int() {
 21)   1.800 us    |                    create_page_buffers();
 21)   5.540 us    |                  }
 21)   9.180 us    |                }
 21) + 51.300 us   |              }
 21)   1.880 us    |              flush_dcache_page();
 21)               |              ext4_da_write_end() {
 21)               |                generic_write_end() {
 21)               |                  block_write_end() {
 21)   1.900 us    |                    flush_dcache_page();
 21)               |                    __block_commit_write.isra.41() {
 21)   1.880 us    |                      mark_buffer_dirty();
 21)   5.690 us    |                    }
 21) + 13.040 us   |                  }
 21)   1.930 us    |                  unlock_page();
 21)               |                  __mark_inode_dirty() {
 21)               |                    ext4_dirty_inode() {
 21)               |                      __ext4_journal_start_sb() {
 21)   1.880 us    |                        ext4_journal_check_start();
 21)   5.600 us    |                      }
 21)               |                      ext4_mark_inode_dirty() {
 21)               |                        ext4_reserve_inode_write() {
 21)               |                          __ext4_get_inode_loc() {
 21)   1.980 us    |                            ext4_get_group_desc();
 21)   1.880 us    |                            ext4_inode_table();
 21)               |                            __getblk_gfp() {
 21)               |                              __find_get_block() {
 21)   1.980 us    |                                mark_page_accessed();
 21) + 60.640 us   |                              }
 21) + 64.300 us   |                            }
 21) + 75.570 us   |                          }
 21)   1.820 us    |                          __ext4_journal_get_write_access();
 21) + 82.950 us   |                        }
 21)               |                        ext4_mark_iloc_dirty() {
 21)               |                          from_kuid() {
 21)   1.940 us    |                            map_id_up();
 21)   5.650 us    |                          }
 21)               |                          from_kgid() {
 21)   1.870 us    |                            map_id_up();
 21)   5.610 us    |                          }
 21)               |                          from_kprojid() {
 21)   1.840 us    |                            map_id_up();
 21)   5.480 us    |                          }
 21)   1.880 us    |                          ext4_inode_csum_set();
 21)               |                          __ext4_handle_dirty_metadata() {
 21)   1.870 us    |                            mark_buffer_dirty();
 21)   5.560 us    |                          }
 21)   1.970 us    |                          __brelse();
 21) + 39.810 us   |                        }
 21) ! 128.380 us  |                      }
 21)   1.920 us    |                      __ext4_journal_stop();
 21) ! 143.280 us  |                    }
 21) ! 147.140 us  |                  }
 21) ! 169.570 us  |                }
 21)   1.850 us    |                __ext4_journal_stop();
 21) ! 176.930 us  |              }
 21)   2.230 us    |              _cond_resched();
 21)   2.170 us    |              balance_dirty_pages_ratelimited();
 21) ! 246.660 us  |            }
 21) ! 254.710 us  |          }
 21) ! 262.830 us  |        }
 21) ! 266.700 us  |      }
 21) ! 270.420 us  |    }
 21)   1.940 us    |    __sb_end_write();
 21) ! 285.880 us  |  }
 21)               |  vfs_write() {
 21)   2.360 us    |    rw_verify_area();
 21)               |    __vfs_write() {
 21)   1.900 us    |      write_null();
 21)   5.830 us    |    }
 21) + 15.560 us   |  }
 ------------------------------------------
 20)  syslogd-3299  =>   <...>-3318
 ------------------------------------------

 20)               |  vfs_write() {
 20)   2.280 us    |    rw_verify_area();
 20)   1.910 us    |    __sb_start_write();
 20)               |    __vfs_write() {
#

```

## 参考
[linux-5.4.74](https://elixir.bootlin.com/linux/v5.4.74/source)
