#!/usr/bin/env bash
# 用 WSL 侧构建产物符号化崩溃/卡死地址（相对于 exe_base 的偏移）
OBJ=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
SYM=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-symbolizer
"$SYM" --obj="$OBJ" --functions=linkage --inlines "$@"
