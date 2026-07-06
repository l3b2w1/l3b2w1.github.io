---
layout:     post
title:      codebuddy webGUI
subtitle:   codebuddy webGUI 使用
date:       2026-07-03
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - ai
---

### 1. Centos服务器
服务器ip地址`1.2.3.4`  

执行命令启动服务
`codebuddy --serve --host 0.0.0.0 --port 9527`
```
# codebuddy --serve --host 0.0.0.0 --port 9527
CodeBuddy Code HTTP Server
Endpoint    http://0.0.0.0:9527
Web UI      http://0.0.0.0:9527/?password=2ynw9PRCCGONJneqLz4cB5GsXFlQaxqV

Password    2ynw9PRCCGONJneqLz4cB5lkXFlQaxqV
Config      /root/.codebuddy/settings.json

Press Ctrl+C to stop the server
```

### 2. PC shell终端
执行命令转发数据  `ssh-L 7890:127.0.0.1:9527 root@1.2.3.4`

有服务器的 SSH 权限，就可以使用 SSH 隧道（最稳妥，无需开放公网）  
强烈建议使用本地转发，这样有流量都走加密隧道，  
前端请求也会指向本地的 127.0.0.1，不会出现地址不匹配问题。


### 3.浏览器访问
`http://127.0.0.1:7890`  
把启动服务时显示的密码输入页面密码提示框，即可登录成功。
