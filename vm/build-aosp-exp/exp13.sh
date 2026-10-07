#!/system/bin/sh
# 实验 13：换了纯 asm 协程后端后，访客能否越过 virtio-blk 后第一次读盘（挂载 system.img）
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g13.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -monitor none -serial file:/data/local/tmp/g13.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 75
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE_AFTER_75s"; else echo "STATUS=EXITED"; fi
  echo "=== 访客行数 ==="
  wc -l /data/local/tmp/g13.log
  echo "=== 从 virtio_blk 起 ==="
  grep -n 'virtio_blk' /data/local/tmp/g13.log
  echo "=== tail 30 ==="
  tail -30 /data/local/tmp/g13.log
} > /data/local/tmp/exp13.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> /data/local/tmp/exp13.txt
