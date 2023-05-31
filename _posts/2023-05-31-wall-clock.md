---
layout:     post
title:      系统时间慢于世界时间
subtitle:   System time is slower than real-world time
date:       2023-05-31
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - time
    - mips
    - loongson
---
2.6.26内核 loongson3a2000系统上遇到一个系统时间比世界时间慢的问题  

内核中mips_hpt_frequency全局变量记录了CPU主频  

1. cpu主频是在bootware初始化硬件的时候，写入倍频系数到寄存器，这就决定了cpu的工作频率，也就是时钟周期  
也决定了counter计数器的cycle递增速率，每秒钟递增多大数值
 
2. 系统启动时，内核从RTC real-time clock读取一次时间后，就不再访问它了  
内核更新系统时间wall clock 会频繁读取counter计数器   
前后两次读取计数器cycle数值，计算二者差值delta cycles，再乘以每个cycle代表的单位时间，就是逝去的时间  
```
delta = ((curr_cycle - old_cycle ) * NS_PER_SEC) / (cpu_clock_freq / ratio )  
```

3. 以纳秒为单位，用于计算相对时间差，根据这个差值更新系统时间，就是 xtime / xtime_cache 全局变量  
```
do_timer -> update_times -> update_wall_time -> update_xtime_cache  
```

4. 用户态执行date命令就会系统调用陷入内核走do_gettimeofday接口  
  读xtime获取wall clock系统当前时间  

5. 向内核传参 cpuclock=800000000 就确定了cpu_clock_freq 的值 为800MHz  
龙芯芯片有一个自定义的ratio，和FAE了解其数值是2  
也就是 每秒钟counter计数器递增的最大数值为 800M/2 = 400M cycles  那么每个cycle单位时间1/400M 秒  
内核会保留一个优化后的数值，每次计算可以避免除法运算，而是使用乘法运算

6. 如果CPU实际工作频率和告诉内核的频率值不一致，就会出现系统时间相比实际时间过快或者过慢的问题  
a. cpu实际工作频率小于向内核传参的数值，系统时间变慢  
b. cpu实际工作频率大于向内核传参的数值，系统时间变快   

比如cpu实际工作频率786MHZ，告诉内核的却是800MHZ，相当于内核掌握的递增每个cycle的单位时间变小  
再从counter计数器获取delta 后乘以单位时间，算出的逝去的时间整体变小，所以导致系统时间变慢  
对比实际世界时间 ```Xtime += delta```变小
