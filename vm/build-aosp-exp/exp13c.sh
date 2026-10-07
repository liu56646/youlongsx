#!/system/bin/sh
# 实验 13c：打开内嵌崩溃捕获，抓新协程后端首次切换的崩溃现场
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
export VMHOST_CRASH_CAPTURE=1
unset VMHOST_CRASH_UNWIND
rm -f /data/local/tmp/g13c.log /data/local/tmp/qemu_crash.txt /data/local/tmp/crash_installed.txt
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -monitor none -serial file:/data/local/tmp/g13c.log \
  < /dev/null > /data/local/tmp/qemu_out.log 2>/data/local/tmp/qemu_err.log &
QPID=$!
echo "QPID=$QPID"
sleep 25
if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
kill -9 "$QPID" 2>/dev/null
echo "=== crash_installed ==="
cat /data/local/tmp/crash_installed.txt 2>&1
echo "=== qemu_crash.txt (head 8) ==="
head -8 /data/local/tmp/qemu_crash.txt 2>&1
echo "=== qemu stderr (head 20) ==="
head -20 /data/local/tmp/qemu_err.log
echo "=== guest 行数 ==="
wc -l /data/local/tmp/g13c.log
