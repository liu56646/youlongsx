#!/system/bin/sh
# 实验 10：用 monitor 在卡住后 dump 访客寄存器，拿到 PC
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g10.log
: > /data/local/tmp/exp10.log
( sleep 70; printf 'info registers\n' ; sleep 4; printf 'info cpus\n' ; sleep 2; printf 'quit\n' ) | \
timeout 120 /dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -serial file:/data/local/tmp/g10.log -monitor stdio \
  > /data/local/tmp/exp10.log 2>&1
echo "=== guest tail ===" >> /data/local/tmp/exp10.log
tail -4 /data/local/tmp/g10.log >> /data/local/tmp/exp10.log 2>&1
