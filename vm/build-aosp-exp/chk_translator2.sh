#!/bin/bash
NM=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm
echo "=== 翻译器 .o 里的 gles1 符号 ==="
$NM /root/vmbuild/gfxstream-build-arm64-v8a/host/gl/glestranslator/GLES_CM/CMakeFiles/GLES_CM_translator_static.dir/GLEScmImp.cpp.o 2>/dev/null | grep -iE 'glShadeModel|glColor4f|glFogxv' | head
echo "=== backend 静态库里是否有 translator 符号 ==="
$NM /root/vmbuild/gfxstream-build-arm64-v8a/host/libgfxstream_backend_static.a 2>/dev/null | grep -iE 'translator.*glShadeModel|translator.*glColor4f' | head
echo "=== backend 静态库是否含 GLEScmImp 目标 ==="
ar t /root/vmbuild/gfxstream-build-arm64-v8a/host/libgfxstream_backend_static.a 2>/dev/null | grep -i 'GLEScm\|GLES_CM' | head
echo "=== GLES_CM_translator_static 库文件 ==="
find /root/vmbuild/gfxstream-build-arm64-v8a -name '*GLES_CM_translator*' 2>/dev/null | head
