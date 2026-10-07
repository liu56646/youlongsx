#!/bin/bash
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
# 找 gles1_dec 编译产物
OBJ=$(find /root/vmbuild/gfxstream-build-arm64-v8a -name 'gles1_dec.cpp.o' 2>/dev/null | head -1)
echo "OBJ=$OBJ"
if [ -z "$OBJ" ]; then
  OBJ=$(find /root/vmbuild/gfxstream-build-arm64-v8a -name '*.o' 2>/dev/null | grep gles1_dec | head -1)
  echo "OBJ2=$OBJ"
fi
if [ -n "$OBJ" ]; then
  # 看 decode 里对 gles1_noop_proc 的调用（应该大量存在）
  $OD -d "$OBJ" 2>/dev/null | grep -c 'gles1_noop_proc'
  echo "=== glColor4ub 附近的调用 ==="
  $OD -d "$OBJ" 2>/dev/null | grep -B2 -A2 'glColor4ub' | head -20
fi
