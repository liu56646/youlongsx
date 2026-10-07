#!/system/bin/sh
# 实验 9：不用 -nographic/stdin，串口直接写文件，验证 100% CPU 是否来自 stdio chardev
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g9.log
: > /data/local/tmp/exp9.log
timeout 150 /dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -monitor none -serial file:/data/local/tmp/g9.log \
  < /dev/null > /data/local/tmp/exp9.log 2>&1
echo "EXIT=$?" >> /data/local/tmp/exp9.log
echo "=== 访客行数 ===" >> /data/local/tmp/exp9.log
wc -l /data/local/tmp/g9.log >> /data/local/tmp/exp9.log 2>&1
tail -8 /data/local/tmp/g9.log >> /data/local/tmp/exp9.log 2>&1
