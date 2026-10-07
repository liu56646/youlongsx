#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
NDK=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin
echo "--- defined dynamic symbols ---"
"$NDK/llvm-nm" -D --defined-only libhwcdbg.so
echo "--- grep assert ---"
"$NDK/llvm-nm" -D --defined-only libhwcdbg.so | grep -i assert || echo "(none)"
