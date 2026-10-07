#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
NDK=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin
B=/mnt/k/youlongsx/vm/engine/src/main/cpp/prebuilt/qemu-aosp/arm64-v8a/qemu-system-aarch64

echo "=== qemu 二进制符号数 ==="
"$NDK/llvm-nm" --defined-only "$B" 2>/dev/null | wc -l
"$NDK/llvm-nm" -D --defined-only "$B" 2>/dev/null | wc -l

echo "=== qemu +0x1bba82 ==="
"$NDK/llvm-symbolizer" --obj="$B" 0x1bba82 2>/dev/null | head -4
echo "=== qemu +0x1bb6aa ==="
"$NDK/llvm-symbolizer" --obj="$B" 0x1bb6aa 2>/dev/null | head -4
echo "=== qemu +0x2b1b13 (另一个线程 pc) ==="
"$NDK/llvm-symbolizer" --obj="$B" 0x2b1b13 2>/dev/null | head -4
echo "=== qemu +0x41a003 ==="
"$NDK/llvm-symbolizer" --obj="$B" 0x41a003 2>/dev/null | head -4

if [ -f libc_host.so ]; then
  echo "=== libc +0x81e60 (主线程 pc) ==="
  "$NDK/llvm-symbolizer" --obj=libc_host.so 0x81e60 2>/dev/null | head -4
  echo "=== libc +0x40eb8 ==="
  "$NDK/llvm-symbolizer" --obj=libc_host.so 0x40eb8 2>/dev/null | head -4
  echo "=== libc +0x28840 ==="
  "$NDK/llvm-symbolizer" --obj=libc_host.so 0x28840 2>/dev/null | head -4
  echo "=== libc 导出里最近的符号 ==="
  "$NDK/llvm-nm" -D --defined-only libc_host.so 2>/dev/null | sort | awk '$1<="0000000000081e60"' | tail -3
fi
