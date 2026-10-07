#!/bin/bash
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
OBJ=$(find /root/vmbuild/gfxstream-build-arm64-v8a -name 'gles1_server_context.cpp.o' 2>/dev/null | head -1)
echo "OBJ=$OBJ"
$OD -d "$OBJ" > /tmp/gles1_sc.dis 2>/dev/null
echo "lines: $(wc -l < /tmp/gles1_sc.dis)"
# initDispatchByName 里找 glShadeModel 的 getProc 字符串引用 → 对应 store 指令
# 先看字符串地址
$OD -s -j .rodata "$OBJ" 2>/dev/null | grep -i 'glShadeModel' | head -2
