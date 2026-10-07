#!/system/bin/sh
# 诊断 2：挂盘跑到卡住后，通过 TCP monitor 拿访客寄存器 PC，并导出 kernel 供符号化
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g13.log /data/local/tmp/mon.txt
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -serial file:/data/local/tmp/g13.log \
  -monitor tcp:127.0.0.1:4444,server,nowait \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
sleep 60
{ printf 'info registers\n'; sleep 3; printf 'info cpus\n'; sleep 2; printf 'quit\n'; } \
  | nc -w 8 127.0.0.1 4444 > /data/local/tmp/mon.txt 2>&1
sleep 2
kill -9 $QPID 2>/dev/null
cp -f "$IMG/kernel" /data/local/tmp/kernel.bin
chmod 644 /data/local/tmp/kernel.bin
echo "DONE" > /data/local/tmp/diag2.done
