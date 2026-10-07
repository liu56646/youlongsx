#!/bin/bash
echo "=== GLES1 翻译器是否编译 ==="
find /root/vmbuild/gfxstream-build-arm64-v8a -name 'GLEScmImp*.o' 2>/dev/null | head
echo "=== 翻译器是否在静态库里 (nm) ==="
NM=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm
$NM /root/vmbuild/gfxstream-build-arm64-v8a/host/libgfxstream_backend_static.a 2>/dev/null | grep -c 'translator.*gles1.*glShadeModel\|_ZN10translator5gles111glShadeModelEv'
echo "=== OpenGLDispatchLoader 是否被实例化 ==="
grep -rn 'OpenGLDispatchLoader\|getEGLDispatch\|s_gles1' /root/vmbuild/gfxstream/host/gl/OpenGLESDispatch/OpenGLDispatchLoader.cpp 2>/dev/null | head -8
echo "=== 谁调用 gles1_dispatch_init ==="
grep -rn 'gles1_dispatch_init' /root/vmbuild/gfxstream --include='*.cpp' 2>/dev/null | head
echo "=== 谁构造 OpenGLDispatchLoader ==="
grep -rn 'OpenGLDispatchLoader' /root/vmbuild/gfxstream --include='*.cpp' --include='*.h' 2>/dev/null | grep -v 'OpenGLDispatchLoader.cpp:' | head
