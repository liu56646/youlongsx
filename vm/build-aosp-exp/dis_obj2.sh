#!/bin/bash
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
OBJ=/root/vmbuild/gfxstream-build-arm64-v8a/host/gl/gles1_dec/CMakeFiles/gles1_dec.dir/gles1_dec.cpp.o
$OD -d "$OBJ" > /tmp/gles1_dec.dis 2>/dev/null
echo "lines: $(wc -l < /tmp/gles1_dec.dis)"
# glColor4ub case 在源码 1021-1024 行；在反汇编里找 blr 调用
grep -n 'blr' /tmp/gles1_dec.dis | head -40
