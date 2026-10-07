#!/system/bin/sh
# 诊断 5：卡住后给 QEMU 发 SIGABRT，用内嵌崩溃捕获拿到主线程调用栈
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
OUT=/data/local/tmp/diag5.txt
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g16.log /data/local/tmp/qemu_crash.txt /data/local/tmp/crash_installed.txt
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -monitor none -serial file:/data/local/tmp/g16.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 60
  echo "=== 发 SIGABRT ==="
  kill -6 "$QPID"
  sleep 4
  echo "=== crash_installed ==="
  cat /data/local/tmp/crash_installed.txt 2>&1
  echo "=== qemu_crash.txt ==="
  cat /data/local/tmp/qemu_crash.txt 2>&1
  echo "=== guest tail ==="
  tail -3 /data/local/tmp/g16.log
} > "$OUT" 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> "$OUT"
