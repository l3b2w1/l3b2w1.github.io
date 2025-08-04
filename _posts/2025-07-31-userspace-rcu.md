---
layout:     post
title:      userspace rcu
subtitle:   urcu
date:       2025-07-31
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - lock
---

# 用户态rcu锁

[点我看清晰大图](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2025-07-31-urcu.png)

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2025-07-31-urcu.png)

### urcu_qsbr_gp.ctr

读者状态(ctr)和全局状态(gp.ctr)之间的交互关系图  

![](https://raw.githubusercontent.com/l3b2w1/l3b2w1.github.io/master/img/2025-07-31-urcu-gp-ctr.png)

### urcu_qsbr_gp.futex

写者同步等待gp结束

```
sychronize_rcu
	wait_for_readers
		 if (wait_loops >= RCU_QS_ACTIVE_ATTEMPTS)  { // 仍有读者处于临界区未经QS，准备休眠
			 uatomic_store(&urcu_qsbr_gp.futex, -1);    //
			 cds_list_for_each_entry(index, input_readers, node)
				uatomic_store(&index->waiting, 1);
		}

		if (wait_loops >= RCU_QS_ACTIVE_ATTEMPTS)  // 写者进程休眠，等待宽限期结束
			wait_gp();   
				while (uatomic_load(&shmctx->urcu_qsbr_gp.futex) == -1) {
					if (!futex_noasync(&shmctx->urcu_qsbr_gp.futex, FUTEX_WAIT, -1, NULL, NULL, 0))
```

读者宣告QS状态，更新本地ctr
```
rcu_quiescent_state
	_urcu_qsbr_quiescent_state
		_urcu_qsbr_quiescent_state_update_and_wakeup
			urcu_qsbr_wake_up_gp
				if (uatomic_load(&urcu_qsbr_gp.futex) != -1)  
					return 0;    // 写者已经被其它读者唤醒，返回即可
				uatomic_store(&urcu_qsbr_gp.futex, 0);   // 清零等待标记
				futex_noasync(&urcu_qsbr_gp.futex, FUTEX_WAKE, 1 ,NULL, NULL, 0);  // 唤醒写者
```

### crdp->futex

写者唤醒调用call_rcu，注册自己的释放内促的回调函数，并唤醒 call rcu thread
```
call_rcu
	_call_rcu
		cds_wfcq_enqueue(&crdp->cbs_head, &crdp->cbs_tail, &head->next); // 回调加入队列
		wake_call_rcu_thread  // 唤醒回调线程 call rcu thread
			call_rcu_wake_up
				futex_async(&crdp->futex, FUTEX_WAKE, 1, NULL, NULL, 0) < 0)  // crdp.futex
```

回收线程
```
call_rcu_thread
	if (splice_ret != CDS_WFCQ_RET_SRC_EMPTY) { // 遍历链表并执行回调
		__cds_wfcq_for_each_blocking_safe(&cbs_tmp_head, &cbs_tmp_tail, cbs, cbs_tmp_n) {
			rhp = caa_container_of(cbs, struct rcu_head, next);  
			rhp->func(rhp);
		}
	}

	if (cds_wfcq_empty())
		call_rcu_wait(crdp);  // 回调链表空，负责call rcu thread 线程进入等待
			while (uatomic_load(&crdp->futex) == -1)
                  if (!futex_async(&crdp->futex, FUTEX_WAIT, -1, NULL, NULL, 0))
```

### 参考
[liburcu](http://liburcu.org/)
