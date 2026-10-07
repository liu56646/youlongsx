#!/bin/bash
# 从手机拉二进制，验证修复特征：qemu_thread_register_setup_callback 的数组追加
# 反汇编找: cmp w8,#0x7; b.gt; add w10,w8,#0x1; ... str x0,[x9,x8,lsl#3]
cd /root/vmbuild
adb shell "cat /dev/vexp/qemu-system-aarch64" > /tmp/phone_qemu.bin
echo "phone binary size: $(stat -c%s /tmp/phone_qemu.bin)"
OD=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump
$OD -d /tmp/phone_qemu.bin > /tmp/phone_qemu.dis 2>/dev/null
echo "disasm lines: $(wc -l < /tmp/phone_qemu.dis)"
# 数组追加特征：add w10, w8, #0x1 紧接着 str w10（递增计数）+ str x0,[x9,x8,lsl#3]
grep -n 'add.*w10, w8, #0x1' /tmp/phone_qemu.dis | head -5
echo "--- lsl#3 store (array write) ---"
grep -n 'str.*x0, \[x9, x8, lsl #3\]' /tmp/phone_qemu.dis | head -5
