#!/system/bin/sh
# 决定性实验：不带 emulator 前端，仅用 QEMU 自身 + -M ranchu 带起 Android 11 访客
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
DATA=/data/user/0/com.vm.app/files/vms/vm_1
LOG=/data/local/tmp/exp1.log
cd /dev/vexp
export LD_LIBRARY_PATH=/dev/vexp
: > "$LOG"
echo "=== 参数 ===" >> "$LOG"
echo "kernel=$IMG/kernel" >> "$LOG"
ls -l "$IMG" >> "$LOG" 2>&1
echo "=== 启动 ===" >> "$LOG"
timeout 150 /dev/vexp/qemu-system-aarch64 \
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
