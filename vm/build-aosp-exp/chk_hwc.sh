#!/bin/bash
RO=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf
echo "=== hwc NEEDED ==="
$RO -d /tmp/hwc_patched2.so 2>/dev/null | grep NEEDED
echo "=== hwc 里 GLES1/GLES2 相关字符串 ==="
strings /tmp/hwc_patched2.so 2>/dev/null | grep -iE 'GLESv1|GLESv2|libEGL|glMatrix|glShade|glColor4|glVertexPointer|glOrtho|glFrustum' | head -20
echo "=== hwc 动态符号(UND) 里的 gl* ==="
$RO -s /tmp/hwc_patched2.so 2>/dev/null | grep -iE 'UND.*gl[A-Z]' | head -20
