#!/usr/bin/env bash
# 校验新协程后端是否真的进了可执行体
NM=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm
EXE=/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
echo "=== 后端符号 ==="
"$NM" "$EXE" 2>/dev/null | grep -iE 'co_ctx_switch|co_start_trampoline|coroutine_trampoline|qemu_coroutine_switch' || true
echo "=== 旧后端残留（应为空）==="
"$NM" "$EXE" 2>/dev/null | grep -i 'coroutine_sigaltstack\|coroutine_trampoline' || true
echo "=== 反汇编 co_ctx_switch ==="
OBJDUMP=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
"$OBJDUMP" -d --disassemble-symbols=co_ctx_switch "$EXE" 2>/dev/null | head -40
