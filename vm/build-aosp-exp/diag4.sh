#!/system/bin/sh
# 诊断 4：卡住时抓 QEMU 主线程的原生栈 / 内核栈 / 系统调用
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
OUT=/data/local/tmp/diag4.txt
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g15.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -monitor none -serial file:/data/local/tmp/g15.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
echo "QPID=$QPID" > "$OUT"
sleep 60

MAIN=$QPID
{
  echo "=== debuggerd -b (native backtrace of all threads) ==="
  debuggerd -b "$MAIN" 2>&1 | head -80
  echo "=== 主线程 wchan / syscall ==="
  cat /proc/$MAIN/wchan 2>&1; echo
  cat /proc/$MAIN/syscall 2>&1; echo
  echo "=== 主线程内核栈 ==="
  cat /proc/$MAIN/stack 2>&1 | head -20
  echo "=== 各线程 wchan ==="
  for d in /proc/$QPID/task/*; do
    t=$(basename "$d")
    echo "tid=$t wchan=$(cat $d/wchan 2>/dev/null) syscall=$(cat $d/syscall 2>/dev/null)"
  done
  echo "=== guest tail ==="
  tail -3 /data/local/tmp/g15.log
} >> "$OUT" 2>&1

kill -9 $QPID 2>/dev/null
echo DONE >> "$OUT"
