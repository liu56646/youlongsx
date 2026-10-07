#!/system/bin/sh
# 实验 13b：前台捕获 QEMU 的 stdout/stderr，定位为何没有访客输出
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g13b.log /data/local/tmp/qemu_err.log /data/local/tmp/qemu_out.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -monitor none -serial file:/data/local/tmp/g13b.log \
  < /dev/null > /data/local/tmp/qemu_out.log 2>/data/local/tmp/qemu_err.log &
QPID=$!
echo "QPID=$QPID"
sleep 25
if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; kill -9 "$QPID"; else echo "STATUS=EXITED"; fi
echo "=== qemu stderr ==="
cat /data/local/tmp/qemu_err.log
echo "=== qemu stdout ==="
head -20 /data/local/tmp/qemu_out.log
echo "=== guest 行数 ==="
wc -l /data/local/tmp/g13b.log
echo "=== guest tail ==="
tail -12 /data/local/tmp/g13b.log
