#!/system/bin/sh
# 实验 7：只挂一个盘（system/super），隔离「多盘探测」是否导致自旋
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
LOG=/data/local/tmp/exp7.log
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
: > "$LOG"
timeout 150 /dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -no-reboot -nographic >> "$LOG" 2>&1
echo "EXIT=$?" >> "$LOG"
