#!/system/bin/sh
# 实验 11：不挂任何磁盘，判断卡点是否由 virtio-blk 探测引起
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g11.log
timeout 90 /dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -display none -monitor none -serial file:/data/local/tmp/g11.log \
  < /dev/null > /dev/null 2>&1
{
  echo "=== guest 行数 ==="
  wc -l /data/local/tmp/g11.log
  echo "=== tail 15 ==="
  tail -15 /data/local/tmp/g11.log
} > /data/local/tmp/exp11.txt 2>&1
