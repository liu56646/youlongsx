#!/system/bin/sh
# 实验 3：区分崩溃 vs 挂起，并在存活时抓取原生调用栈
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
DATA=/data/user/0/com.vm.app/files/vms/vm_1
LOG=/data/local/tmp/exp3.log
BT=/data/local/tmp/exp3.bt
cd /dev/vexp
export LD_LIBRARY_PATH=/dev/vexp
: > "$LOG"
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -drive if=none,id=vendor,file="$IMG/vendor.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=vendor \
  -drive if=none,id=userdata,file="$DATA/userdata.img",format=raw \
  -device virtio-blk-device,drive=userdata \
  -no-reboot -nographic >> "$LOG" 2>&1 &
QPID=$!
sleep 25
if kill -0 "$QPID" 2>/dev/null; then
  echo "STATUS=ALIVE_AFTER_25s pid=$QPID" >> "$LOG"
  debuggerd -b "$QPID" > "$BT" 2>&1
  kill -9 "$QPID"
  echo "STATUS=KILLED_BY_SCRIPT" >> "$LOG"
else
  wait "$QPID"
  echo "STATUS=EXITED code=$?" >> "$LOG"
fi
