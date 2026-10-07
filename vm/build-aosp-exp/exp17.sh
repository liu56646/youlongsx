#!/system/bin/sh
# 实验 17：补齐模拟器常用引导参数，看静默重启是否消失
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g17.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 2 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 qemu=1 androidboot.qemu=1 ignore_loglevel panic=0" \
  -drive if=none,id=meta,file=/data/local/tmp/meta.img,format=raw \
  -drive if=none,id=data,file=/data/local/tmp/data.img,format=raw \
  -drive if=none,id=vendor,file="$IMG/vendor.img",format=raw,readonly=on \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=meta \
  -device virtio-blk-device,drive=data \
  -device virtio-blk-device,drive=vendor \
  -device virtio-blk-device,drive=system \
  -no-reboot -display none -monitor none -serial file:/data/local/tmp/g17.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 110
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 行数 ==="
  wc -l /data/local/tmp/g17.log
  echo "=== init 相关 ==="
  grep -nE 'init:|bootloader|Failed|logd|zygote|system_server|Mount' /data/local/tmp/g17.log | tail -30
  echo "=== tail 15 ==="
  tail -15 /data/local/tmp/g17.log
} > /data/local/tmp/exp17.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> /data/local/tmp/exp17.txt
