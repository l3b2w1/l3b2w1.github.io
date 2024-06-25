---
layout:     post
title:      git常用命令
subtitle:   Common Git Commands
date:       2023-08-10
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - git
---

### 分支操作
git clone git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git

git tag     // 查看所有发布版本

git checkout v6.4.9    // 切换分支

git checkout -b develop   // 创建并切换到develop分支

git branch test //创建新分支，但是并不切换过去

git branch  //查看所有分支，以及当前所在分支

git checkout master // 切回master分支  

git pull    // 拉取最新提交

git branch -D develop2   // -d 删除分支develop ; -D 强制删除分支develop2

git remote -v    // 查询远程仓库URL  

git branch -m old-branch new-branch  // 重命名分支，当前位于old-branch

git tag -a tagName -m "comment"   // 打标签  
git tag -d tagName                // 删标签  

### 查看历史改动
git status --untracked-files=no   // 不显示未跟踪的文件

git log --oneline arch/riscv       // 查看riscv相关历史改动  

查看riscv架构ftrace功能相关的提交，指定范围 `76d2a0493a17^..v6.4.9`  
```
git rev-list --oneline 76d2a0493a17^..v6.4.9 --reverse arch/riscv | grep -i ftrace  
```

列出每个 Commit 的标题（--oneline），按照逆序的方式排列（--reverse），过滤掉非核心的代码（egrep）   
```
git rev-list --oneline 76d2a0493a17^..v6.4.9 --reverse arch/riscv
    | egrep -v " Merge | Backmerge | dts| kbuild| asm-generic| firmware| include|  
      Documentation| Revert| drivers | config | Rename"
```

### 查看patch内容
git show 2ca39528c01a933f6689cd6505ce65bd6d68a530    // 根据commitID显示对应patch内容

git log -p -1 aafj23kfandfa23wke > ~/new.patch  // 提取 patch代码保存到文件中

### 提交相关
git reset --hard 3014a025e     // 恢复至某次提交，删除的是已跟踪的文件（即commit后的文件）

git clean -nxdf && git checkout . && git clean -xdf  // 丢弃本地临时修改（未commit的文件）

git reset --hard HEAD^     // 撤销最近的一次提交

git reflog      // 查看所有提交  

git reset HEAD Makefile    // 恢复误删的文件    
git checkout Makefile

git reset --mixed // 回退git add 操作，add文件退出暂存区，保留本地修改  
git retore arch // 放弃跟踪误提交的arch下中间文件  

git checkout -b crop  200d35d6 // 基于当前分支的某次提交ID 200d35d6创建新分支  

git checkout new-branch && git merge --squash many-commits-branch // 从包含多次提交的分支squash并merge到新分支

### 给内核提交patch
git status   // 查看修改文件

git add kernel/dma/contiguous.c    // 修改文件加入暂存区

git commit -s -v        // 这一次提交的id 为 60489cb7

git commit -s --amend     // 在文本编辑器中修改commit log

git notes append -m "v3: zzzzzzzz" 60489cb7   // 添加备注说明

git notes append -m "v2: yyyyyyyy" 60489cb7

git notes append -m "v1: xxxxxxxx" 60489cb7

git branch --set-upstream-to=master      //设置以主线为基线

./scripts/checkpatch.pl --strict -g HEAD    // 严格检查最新提交，避免格式问题被打回来

git format-patch --notes -v3 --signoff --base=auto master  // 生成带 notes(changelog) 和 signoff 的v3版patch

./scripts/get_maintainer.pl v3-0001-to-applied-to-v6.5.patch   // 获取maintainer邮箱地址

git send-email --to maintainer@gmail.com --cc reviewer@gmail.com v3-0001-to-applied-to-v6.5.patch   // 邮件发送patch
