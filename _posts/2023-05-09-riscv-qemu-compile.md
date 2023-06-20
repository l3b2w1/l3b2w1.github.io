---
layout:     post
title:      riscv相关组件编译
subtitle:   qemu启动riscv镜像
date:       2023-06-05
author:     icecube
header-img: img/bluelinux.jpg
catalog: true
tags:
    - riscv
    - qemu
---

### 编译 qemu-system-riscv64
```
git clone https://github.com/qemu/qemu
cd qemu
git checkout v7.2.
mkdir build
cd build
../configure --prefix=/home/linux/riscv/qemu-7.2.0-install/ \
    --target-list=riscv32-softmmu,riscv64-softmmu --enable-debug-tcg \
    --enable-debug --enable-debug-info --enable-slirp \
    --enable-user && make -j && make install
```

### 编译u-boot.bin
下载并解压u-boot源码  
```
unzip u-boot-master.zip  
cd u-boot-master/  
make CROSS_COMPILE=riscv64-unknown-linux-gnu- qemu-riscv64_smode_defconfig  
make CROSS_COMPILE=riscv64-unknown-linux-gnu- all -j  
```
### 编译OpenSBI

下载opensbi源码  
git clone https://github.com/riscv-software-src/opensbi  

编译  
ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- PLATFORM=generic PLATFORM_RISCV_XLEN=64 make all -j  

生成如下fw文件
```
./build/platform/generic/firmware/fw_jump.bin  
./build/platform/generic/firmware/fw_dynamic.bin  
./build/platform/generic/firmware/fw_payload.bin

./build/platform/generic/firmware/fw_payload.elf
./build/platform/generic/firmware/fw_jump.elf
./build/platform/generic/firmware/fw_dynamic.elf
```

### qemu调试启动 fw_payload
/home/linux/riscv/qemu-7.2.0-install/bin/qemu-system-riscv64 -M virt -m 256M -nographic -bios build/platform/generic/firmware/fw_payload.elf -s -S  

调试opensbi的代码    
riscv-gdb ./build/platform/generic/firmware/fw_payload.elf  

### 编译uboot fw_payload  
V=1 ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- FW_PAYLOAD=y PLATFORM=generic PLATFORM_RISCV_XLEN=64 FW_PAYLOAD_PATH=./u-boot.bin make -j

### qemu启动u-boot  
根据 QEMU 官方文档，当没有 -bios 这一启动参数时，QEMU 将会加载自带的 OpenSBI firmware。   
而当使用 -bios none 作为启动参数时，QEMU 就不会自动加载任何 firmware。   
当使用 -bios <file> 指定了特定文件作为 firmware 时，QEMU 就会加载我们指定的那个 firmware。  

qemu-system-riscv64 -M virt -m 256M -nographic -bios build/platform/generic/firmware/fw_jump.bin -kernel /path/to/u-boot.bin      
qemu-system-riscv64 -M virt -smp 4 -m 2G  -nographic -display none -kernel /path/to/u-boot.bin    

### 启动riscv镜像
```
qemu-system-riscv64 \
        -M virt -m 4096M -smp 4 \
        -kernel arch/riscv/boot/Image \
        -append "root=/dev/vda ro console=ttyS0" \
        -drive file=riscv-rootfs.ext2,format=raw,id=hd0 \
        -device virtio-blk-device,drive=hd0 -netdev user,id=net0 -device virtio-net-device,netdev=net0 \
        -nographic
```
```
qemu-system-riscv64 \
    -machine virt \
    -cpu rv64 \
    -m 1G \
    -device virtio-blk-device,drive=hd \
    -drive file=overlay.qcow2,if=none,id=hd \
    -device virtio-net-device,netdev=net \
    -netdev user,id=net,hostfwd=tcp::2222-:22 \
    -bios /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.elf \
    -kernel /usr/lib/u-boot/qemu-riscv64_smode/uboot.elf \
    -object rng-random,filename=/dev/urandom,id=rng \
    -device virtio-rng-device,rng=rng \
    -append "root=LABEL=rootfs console=ttyS0" \
    -nographic
```
### 提取qemu自带的dtb
qemu-system-riscv64 -M virt,dumpdtb=qemu.dtb
qemu-system-riscv64 -machine virt -machine dumpdtb=qemu.dtb

转换成dts文件
dtc -I dtb -O dts -o qemu-virt.dts qemu.dtb


### 手动编译gdb
PREFIX=$(pwd)/gdb-8.3.1-riscv64-linux-gnu  
wget ftp://ftp.gnu.org/gnu/gdb/gdb-8.3.1.tar.xz  
tar Jxf gdb-8.3.1.tar.xz  
mkdir gdb  
cd gdb  
../gdb-8.3.1/configure --program-prefix=riscv64-linux-gnu- -with-tui --target=riscv64-linux-gnu --prefix=${PREFIX}  
make all install

### 参考索引
https://github.com/riscv-software-src/opensbi/blob/master/docs/platform/qemu_virt.md    
https://colatkinson.site/linux/riscv/2021/01/27/riscv-qemu/
