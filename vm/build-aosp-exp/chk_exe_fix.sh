#!/bin/bash
# 在 exe 里搜 qemu_thread_register_setup_callback 的"数组追加"特征
# （cmp w8,#0x7; b.gt; add w10,w8,#0x1）来确认修复在不在二进制里。
cd /root/vmbuild
EXE=qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
echo "exe size: $(stat -c%s $EXE)"
# 搜索包含 "cmp w8, #0x7" 的序列（数组上限检查，旧代码是单槽位赋值没有这个）
$OD -d $EXE | grep -c 'cmp.*w8, #0x7'
echo "--- context around first match ---"
$OD -d $EXE | grep -B3 -A3 'cmp.*w8, #0x7' | head -20
