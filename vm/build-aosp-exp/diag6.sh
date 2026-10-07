#!/system/bin/sh
# 诊断 6：unwinder 关闭后，看原始信号是否暴露出来（handler 会记录并 _exit）
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
OUT=/data/local/tmp/diag6.txt
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g17.log /data/local/tmp/qemu_crash.txt
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -monitor none -serial file:/data/local/tmp/g17.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 45
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE_AFTER_45s"; else echo "STATUS=EXITED"; fi
  echo "=== qemu_crash.txt ==="
  cat /data/local/tmp/qemu_crash.txt 2>&1
  echo "=== guest tail ==="
  wc -l /data/local/tmp/g17.log
  tail -6 /data/local/tmp/g17.log
} > "$OUT" 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> "$OUT"
