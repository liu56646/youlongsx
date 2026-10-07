#!/system/bin/sh
# 实验 12：挂盘 + -smp 1，隔离多核是否是触发条件
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g12.log
timeout 90 /dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -monitor none -serial file:/data/local/tmp/g12.log \
  < /dev/null > /dev/null 2>&1
{
  echo "=== guest 行数 ==="
  wc -l /data/local/tmp/g12.log
  echo "=== tail 18 ==="
  tail -18 /data/local/tmp/g12.log
} > /data/local/tmp/exp12.txt 2>&1
