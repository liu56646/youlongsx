#!/system/bin/sh
# 检查 qemu 二进制里是否编入了崩溃捕获字符串
strings /dev/vexp/qemu-system-aarch64 | grep -F "VMHOST QEMU CRASH" | head -2
echo "count="$(strings /dev/vexp/qemu-system-aarch64 | grep -cF "VMHOST QEMU CRASH")
