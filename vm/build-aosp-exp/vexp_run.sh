#!/system/bin/sh
# 实验辅助：把 AOSP QEMU 二进制搬到可执行的 tmpfs 上并运行
set -x
mkdir -p /dev/vexp
cp -f /data/local/tmp/vmaosp/* /dev/vexp/
chmod 755 /dev/vexp/qemu-system-aarch64
chmod 755 /dev/vexp/*.so
cd /dev/vexp
LD_LIBRARY_PATH=/dev/vexp ./qemu-system-aarch64 "$@"
