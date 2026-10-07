#!/system/bin/sh
# 实验 18：用带探针的 initramfs，rdinit=/dumper 先 dump 块设备/sysfs，再 exec /init
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g18.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 2 -m 2048 \
  -kernel "$IMG/kernel" -initrd /data/local/tmp/ramdisk_dump.img \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled rdinit=/dumper ignore_loglevel panic=0" \
  -drive if=none,id=meta,file=/data/local/tmp/meta.img,format=raw \
  -drive if=none,id=data,file=/data/local/tmp/data.img,format=raw \
  -drive if=none,id=vendor,file="$IMG/vendor.img",format=raw,readonly=on \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=meta \
  -device virtio-blk-device,drive=data \
  -device virtio-blk-device,drive=vendor \
  -device virtio-blk-device,drive=system \
  -no-reboot -display none -monitor none -serial file:/data/local/tmp/g18.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 60
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== DUMP 段（最后 80 行）==="
  grep -aE 'DUMP:' /data/local/tmp/g18.log | tail -80
  echo "=== 之后 init 相关 ==="
  grep -naE 'init:|by-name|super|Failed' /data/local/tmp/g18.log | tail -15
} > /data/local/tmp/exp18.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> /data/local/tmp/exp18.txt
