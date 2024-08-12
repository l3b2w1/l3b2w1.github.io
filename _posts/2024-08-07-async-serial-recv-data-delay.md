---
layout:     post
title:      async serial port recv data delayed
subtitle:   异步串口收包延迟问题
date:       2024-08-07
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - tty
---
## 背景
路由器产品反馈应用程序epoll_wait等着读串口驱动数据出现30ms左右延迟。  

数据从底层向上层应用传送流程：  
`serial port driver -->  tty ldisck ---> application(tty read)`

数据从驱动到应用涉及到的内核函数流程  
`串口驱动 tty_flip_buffer_push -> queue_work(system_unbound_wq, &buf->work) ->   
flush_to_ldisc -> receive_buf-> n_tty_receive_buf_common-> wake_up_interruptible_poll`   
最后由`wake_up_interruptible_poll` 通过epoll事件 唤醒daemon程序读取数据。

### 定位思路
梳理清楚数据传输流程，在传输数据的各个关键节点插入探测点  
并且打开 tracepoint 事件，根据时间戳核查到底哪个环节引入的延迟。  
也是为了排除内核自身问题，产品找不到原因的时候总是瞎怀疑，说调度不及时，tty有问题。。。

打开 ftrace 下的 sched workqueue 事件，同时在上面几个关键函数插入探测点
```
mount -t debugfs nodev /sys/kernel/debug
cd /sys/kernel/debug/tracing
echo ffff > tracing_cpumask
```

打开调度事件，主要看线程是否及时调度。
```
echo 1 > events/sched/sched_switch/enable
```

打开workqueue事件跟踪，主要是为了查看流程中涉及到的 kworker 线程执行时间戳。
```
echo 1 > events/workqueue/enable
```

`flush_to_ldisc`插入kretprobe，主要查看提交给ldisc的结束时间。
```
echo 'r:flush flush_to_ldisc' >> kprobe_events
```

在`n_tty_receive_buf_common`入口插入kprobe探测点，打印出接收的字节个数，  
以及对应前四个字节数据内容，和用户态打印的数据做对比，方便从大量日志中快速找到发包条目。
```
echo 'p:recv n_tty_receive_buf_common num=%x0 v0=+0x0(%x1):u8 v1=+0x1(%x1):u8 v1=+0x2(%x1):u8 v1=+0x3(%x1):u8' >> kprobe_events
```

`tty_read`插入kretprobe探测点，返回本次读取的字节个数，也是为了查看对应时间戳。
```
echo 'r:ttyrd tty_read num=%x0' >> kprobe_events
```

### 分析记录
正常情况下每隔5ms会接收并读取一次串口数据。
```
Line 33292:        rtermd-2481  [005] d...  3424.834675: read: (__vfs_read+0x24/0x50 <- tty_read) num=0x4
Line 33503:        rtermd-2481  [005] d...  3424.839666: read: (__vfs_read+0x24/0x50 <- tty_read) num=0x4
Line 33717:        rtermd-2481  [005] d...  3424.844666: read: (__vfs_read+0x24/0x50 <- tty_read) num=0x4
Line 33933:        rtermd-2481  [005] d...  3424.849666: read: (__vfs_read+0x24/0x50 <- tty_read) num=0x4
```

以下是一次正常接收串口数据的流程，从kworker被唤醒开始(3步骤)  到 rtermd tty read结束(10步骤)，   
这个过程耗时只有57微妙( 3426.329697 - 3426.329640 )，  
每一次收包从queue work，到kworker被唤醒 ，再到tty read结束都只有几十微妙。
```
      kipd-836   [001] d...  3426.329633: sched_switch: prev_comm=kipd prev_pid=836 prev_prio=120 prev_state=R ==> next_comm=ttyd next_pid=788 next_prio=120   //  1. cpu 1上进程切换到   ttyd-788
      ttyd-788   [001] d...  3426.329635: wktty1: (__wake_up+0x0/0x70)
      ttyd-788   [001] d...  3426.329637: workqueue_queue_work: work struct=ffffffe0e2001808 function=flush_to_ldisc workqueue=ffffffe0e0006200 req_cpu=64 cpu=4294967295   // 2. ttyd tty_flip_buffer_push -> queue_work 插入work
      ttyd-788   [001] d...  3426.329637: workqueue_activate_work: work struct ffffffe0e2001808
      ttyd-788   [001] d...  3426.329640: sched_switch: prev_comm=ttyd prev_pid=788 prev_prio=120 prev_state=S ==> next_comm=kipd next_pid=836 next_prio=120
    syslogd-2395  [000] dnh.  3426.329640: sched_wakeup: comm=kworker/u16:2 pid=64 prio=120 target_cpu=000    //  3. Cpu 0上的kworker/u16:2 被唤醒
    syslogd-2395  [000] dnh.  3426.329643: wktty1: (__wake_up+0x0/0x70)
    syslogd-2395  [000] dn..  3426.329645: epcnt: (ep_scan_ready_list.isra.2+0x90/0x1f0 <- ep_send_events_proc) cnt=0x0
    syslogd-2395  [000] d...  3426.329647: sched_switch: prev_comm=syslogd prev_pid=2395 prev_prio=120 prev_state=S ==> next_comm=kworker/u16:2 next_pid=64 next_prio=120    // 4. Cpu 0切换到kworker/u16:2
kworker/u16:2-64    [000] ....  3426.329649: workqueue_execute_start: work struct ffffffe0e2001808: function flush_to_ldisc             // 5. kworker/u16:2在 cpu 0上处理插入的work
kworker/u16:2-64    [000] d...  3426.329651: tty1: (n_tty_receive_buf_common+0x0/0xa58) cnt=0x4
kworker/u16:2-64    [000] d...  3426.329651: ttyret: (n_tty_receive_buf_common+0x0/0xa58) cnt=0xffffffe0a7870000
kworker/u16:2-64    [000] d...  3426.329651: tty: (n_tty_receive_buf_common+0x0/0xa58) cnt=0x4 v0=0xb4 v1=0xb5 v2=0xb6 v3=0xb7
kworker/u16:2-64    [000] d...  3426.329653: wktty1: (__wake_up+0x0/0x70)
kworker/u16:2-64    [000] d...  3426.329655: flush: (process_one_work+0x2bc/0x468 <- flush_to_ldisc)
kworker/u16:2-64    [000] ....  3426.329656: workqueue_execute_end: work struct ffffffe0e2001808   //6.  work执行结束
kdrvfwdd5-840   [005] dnh.  3426.329657: sched_wakeup: comm=rtermd pid=2481 prio=100 target_cpu=005    // 7. 等待在epoll tty上的rtermd被唤醒
kworker/u16:2-64    [000] d...  3426.329660: sched_switch: prev_comm=kworker/u16:2 prev_pid=64 prev_prio=120 prev_state=S ==> next_comm=swapper/0 next_pid=0 next_prio=120
      kdrvfwdd5-840   [005] d...  3426.329661: sched_switch: prev_comm=kdrvfwdd5 prev_pid=840 prev_prio=120 prev_state=R ==> next_comm=rtermd next_pid=2481 next_prio=100   // 8.  Cpu5上进程切换到 rtermd
      rtermd-2481  [005] d...  3426.329665: epcnt: (ep_scan_ready_list.isra.2+0x90/0x1f0 <- ep_send_events_proc) cnt=0x1  // 9.  Cpu5 上rtermond 进程epoll_wait返回
      <idle>-0     [000] d.h.  3426.329680: wktty1: (__wake_up+0x0/0x70)
      <idle>-0     [000] d.h.  3426.329686: wktty1: (__wake_up+0x0/0x70)
      <idle>-0     [000] d.h.  3426.329693: wktty1: (__wake_up+0x0/0x70)    
      rtermd-2481  [005] d...  3426.329697: read: (__vfs_read+0x24/0x50 <- tty_read) num=0x4   // 10. rtermd tty_read读取数据
```
根据应用调试信息过滤出有问题的记录 `num=0x14`，这次相差了35ms。
```
Line 34783:        rtermd-2481  [005] d...  3424.869672: read: (__vfs_read+0x24/0x50 <- tty_read) num=0x4
Line 37526:        rtermd-2481  [005] d...  3424.904917: read: (__vfs_read+0x24/0x50 <- tty_read) num=0x14
```

抓到cpu 0 上 bdev 进程，不知道挂到哪里了，处于关中断状态，可能在等什么事件。  
```
<idle>-0     [000] dnh.  3424.871618: sched_wakeup: comm=bdev pid=2400 prio=120 target_cpu=000
<idle>-0     [000] d...  3424.871619: sched_switch: prev_comm=swapper/0 prev_pid=0 prev_prio=120 prev_state=R ==> next_comm=bdev next_pid=2400 next_prio=120
  bdev-2400  [000] d...  3424.871622: epcnt: (ep_scan_ready_list.isra.2+0x90/0x1f0 <- ep_send_events_proc) cnt=0x1    // 从这里开始cpu 0挂在了bdev-2400上
  kipd-840   [005] d.s.  3424.872470: wktty1: (__wake_up+0x0/0x70)
  kipd-840   [005] dns.  3424.872473: sched_wakeup: comm=rtermd pid=2481 prio=100 target_cpu=005
  kipd-840   [005] d...  3424.872482: sched_switch: prev_comm=kipd prev_pid=840 prev_prio=120 prev_state=R ==> next_comm=rtermd next_pid=2481 next_prio=100
rtermd-2481  [005] d...  3424.872486: epcnt: (ep_scan_ready_list.isra.2+0x90/0x1f0 <- ep_send_events_proc) cnt=0x1
  bdev-2400  [000] d.h.  3424.872502: wktty1: (__wake_up+0x0/0x70)
  bdev-2400  [000] d.h.  3424.872508: wktty1: (__wake_up+0x0/0x70)
  bdev-2400  [000] d.h.  3424.872514: wktty1: (__wake_up+0x0/0x70)
  bdev-2400  [000] d.h.  3424.872521: wktty1: (__wake_up+0x0/0x70)
  bdev-2400  [000] d.h.  3424.872530: wktty1: (__wake_up+0x0/0x70)       
rtermd-2481  [005] d...  3424.872535: wktty1: (__wake_up+0x0/0x70)
  bdev-2400  [000] d.h.  3424.872537: wktty1: (__wake_up+0x0/0x70)
           .....
  bdev-2400  [000] d.h.  3424.873779: wktty1: (__wake_up+0x0/0x70)
```

bdev终于执行结束，切换出去，cpu 0上开始正常执行其他业务进程，    
ttyd才开始tty_flip_buffer_push -> queue_work，并且0 核上的kworker也能及时处理work，这两个事件之间没有引入长延迟。
```
3424.904845 这个时间点之后ttyd才开始 tty push并且queue work ，而且   kworker/u16:0-6  和         kworker/u16:2都能及时处理work，
           kipd2-836   [001] d...  3424.904845: sched_switch: prev_comm=kipd2 prev_pid=836 prev_prio=120 prev_state=R ==> next_comm=ttyd next_pid=788 next_prio=120
            bdev-2400  [000] d...  3424.904850: sched_switch: prev_comm=bdev prev_pid=2400 prev_prio=120 prev_state=R ==> next_comm=ksoftirqd/0 next_pid=3 next_prio=120
            ttyd-788   [001] d...  3424.904853: sched_switch: prev_comm=ttyd prev_pid=788 prev_prio=120 prev_state=R ==> next_comm=kipd2 next_pid=836 next_prio=120
     ksoftirqd/0-3     [000] d...  3424.904854: sched_switch: prev_comm=ksoftirqd/0 prev_pid=3 prev_prio=120 prev_state=S ==> next_comm=kworker/u16:0 next_pid=6 next_prio=120
   kworker/u16:0-6     [000] ....  3424.904856: workqueue_execute_start: work struct ffffffe0e2001808: function flush_to_ldisc
   kworker/u16:0-6     [000] d...  3424.904858: tty1: (n_tty_receive_buf_common+0x0/0xa58) cnt=0x4
   kworker/u16:0-6     [000] d...  3424.904858: ttyret: (n_tty_receive_buf_common+0x0/0xa58) cnt=0xffffffe0a7870000
   kworker/u16:0-6     [000] d...  3424.904859: tty: (n_tty_receive_buf_common+0x0/0xa58) cnt=0x4 v0=0x28 v1=0x29 v2=0x2a v3=0x2b
		   kipd2-836   [001] d...  3424.904860: sched_switch: prev_comm=kipd2 prev_pid=836 prev_prio=120 prev_state=R ==> next_comm=ttyd next_pid=788 next_prio=120
   kworker/u16:0-6     [000] d...  3424.904861: wktty1: (__wake_up+0x0/0x70)
….
   kworker/u16:2-64    [000] d...  3424.904910: flush: (process_one_work+0x2bc/0x468 <- flush_to_ldisc)
   kworker/u16:2-64    [000] ....  3424.904910: workqueue_execute_end: work struct ffffffe0e2001808
   kworker/u16:2-64    [000] ....  3424.904911: workqueue_execute_start: work struct ffffffe0e2001808: function flush_to_ldisc
   kworker/u16:2-64    [000] d.h.  3424.904914: wktty1: (__wake_up+0x0/0x70)
   kworker/u16:2-64    [000] d...  3424.904916: flush: (process_one_work+0x2bc/0x468 <- flush_to_ldisc)
   kworker/u16:2-64    [000] ....  3424.904916: workqueue_execute_end: work struct ffffffe0e2001808
          rtermd-2481  [005] d...  3424.904917: read: (__vfs_read+0x24/0x50 <- tty_read) num=0x14
```

所以驱动的bdev内核线程关中断死循环了至少33ms (3424.904845 - 3424.871622)，导致ttyd调度不及时，queue work也就延后了。
进而用户态rtermd tty read也延迟了。

### 相关代码
串口驱动调用 `tty_flip_buffer_push` 把work 挂到 `system_unbound_wq`  
即未绑定cpu的系统 workqueue 队列上，交给 kworker 内核线程推送数据到 tty ldisc 线路规程。

```
   513 void tty_flip_buffer_push(struct tty_port *port)
   514 {
   515         tty_schedule_flip(port);
   516 }
   517 EXPORT_SYMBOL(tty_flip_buffer_push);

   373 void tty_schedule_flip(struct tty_port *port)
   374 {
   375         struct tty_bufhead *buf = &port->buf;
   376
   377         /* paired w/ acquire in flush_to_ldisc(); ensures
   378          * flush_to_ldisc() sees buffer data.
   379          */
   380         smp_store_release(&buf->tail->commit, buf->tail->used);
   381         queue_work(system_unbound_wq, &buf->work);
   382 }
```

port->buf->work的回调就是 `flush_to_ldisc`，该函数冲刷数据到 ldisc。  
具体执行在`receive_buf`中。  

`flush_to_ldisc  ---> receive_buf(tty, head, count);`
```
   448 static void flush_to_ldisc(struct work_struct *work)
   449 {
	         ......
   465         while (1) {
	         ......
   491                 count = receive_buf(tty, head, count);
   492                 if (!count)
   493                         break;
   494                 head->read += count;
   495         }
```

tty_port->buf->work 初始化位置在 `tty_buffer_init`。
```
   525
   526 void tty_buffer_init(struct tty_port *port)
   527 {
   528         struct tty_bufhead *buf = &port->buf;
   529
   530         mutex_init(&buf->lock);
   531         tty_buffer_reset(&buf->sentinel, 0);
   532         buf->head = &buf->sentinel;
   533         buf->tail = &buf->sentinel;
   534         init_llist_head(&buf->free);
   535         atomic_set(&buf->mem_used, 0);
   536         atomic_set(&buf->priority, 0);
   537         INIT_WORK(&buf->work, flush_to_ldisc);
   538         buf->mem_limit = TTYB_DEFAULT_MEM_LIMIT;
   539 }
   540
```

`receive_buf` 调用 tty ldisc 回调  `n_tty_receive_buf`
```
  414 static int
   415 receive_buf(struct tty_struct *tty, struct tty_buffer *head, int count)
   416 {
   417         struct tty_ldisc *disc = tty->ldisc;
   418         unsigned char *p = char_buf_ptr(head, head->read);
   419         char          *f = NULL;
   420
   421         if (~head->flags & TTYB_NORMAL)
   422                 f = flag_buf_ptr(head, head->read);
   423
   424         if (disc->ops->receive_buf2)
   425                 count = disc->ops->receive_buf2(tty, p, f, count);
   426         else {
   427                 count = min_t(int, count, tty->receive_room);
   428                 if (count && disc->ops->receive_buf)
   429                         disc->ops->receive_buf(tty, p, f, count);
   430         }
   431         return count;
   432 }
```

```
   2525 struct tty_ldisc_ops tty_ldisc_N_TTY = {
   2526         .magic           = TTY_LDISC_MAGIC,
   2527         .name            = "n_tty",
   2528         .open            = n_tty_open,
   2529         .close           = n_tty_close,
   2530         .flush_buffer    = n_tty_flush_buffer,
   2531         .chars_in_buffer = n_tty_chars_in_buffer,
   2532         .read            = n_tty_read,
   2533         .write           = n_tty_write,
   2534         .ioctl           = n_tty_ioctl,
   2535         .set_termios     = n_tty_set_termios,
   2536         .poll            = n_tty_poll,
   2537         .receive_buf     = n_tty_receive_buf,
   2538         .write_wakeup    = n_tty_write_wakeup,
   2539         .fasync          = n_tty_fasync,
   2540         .receive_buf2    = n_tty_receive_buf2,
   2541 };
```

```
  1768 static void n_tty_receive_buf(struct tty_struct *tty, const unsigned char *cp,
   1769                               char *fp, int count)
   1770 {
   1771         n_tty_receive_buf_common(tty, cp, fp, count, 0);
   1772 }
```

```
 1698 static int
 1699 n_tty_receive_buf_common(struct tty_struct *tty, const unsigned char *cp,
 1700                          char *fp, int count, int flow)
 1701 {
	.......
 1707         while (1) {
	......
 1741                 if (!overflow || !fp || *fp != TTY_PARITY)
 1742                         __receive_buf(tty, cp, fp, n);
	......
  1749         }
```

负责写入epoll POLLIN事件，唤醒在tty read_wait等待队列上的应用程序，可以调用tty read读取数据了。
```
  1621 static void __receive_buf(struct tty_struct *tty, const unsigned char *cp,
   1622                           char *fp, int count)
   1623 {
	.......
   1655
   1656         /* publish read_head to consumer */
   1657         smp_store_release(&ldata->commit_head, ldata->read_head);
   1658
   1659         if ((read_cnt(ldata) >= ldata->minimum_to_wake) || L_EXTPROC(tty)) {
   1660                 kill_fasync(&tty->fasync, SIGIO, POLL_IN);
   1661                 wake_up_interruptible_poll(&tty->read_wait, POLLIN);
   1662         }
   1663 }
```

## 参考
[linux-4.4.65](https://elixir.bootlin.com/linux/v4.4.65/source)
