#!/system/bin/sh
# 实验 4：LD_PRELOAD 崩溃捕获，拿到 QEMU 侧调用栈
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
DATA=/data/user/0/com.vm.app/files/vms/vm_1
LOG=/data/local/tmp/exp4.log
cd /dev/vexp
cp -f /data/local/tmp/vmaosp/libqemucrash.so /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/*.so
export LD_LIBRARY_PATH=/dev/vexp
: > "$LOG"
rm -f /data/local/tmp/qemu_crash.txt
LD_PRELOAD=/dev/vexp/libqemucrash.so /dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -drive if=none,id=vendor,file="$IMG/vendor.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=vendor \
  -drive if=none,id=userdata,file="$DATA/userdata.img",format=raw \
  -device virtio-blk-device,drive=userdata \
  -no-reboot -nographic >> "$LOG" 2>&1
echo "EXIT=$?" >> "$LOG"
cat /data/local/tmp/qemu_crash.txt >> "$LOG" 2>&1
