#!/system/bin/sh
# 实验 14：按 fstab.ranchu 补齐磁盘
#   vda=system(ro, super) vdb=vendor(ro) vdc=data(ext4) vdd=meta(GPT metadata)
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g14.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 2 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -drive if=none,id=vendor,file="$IMG/vendor.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=vendor \
  -drive if=none,id=data,file=/data/local/tmp/data.img,format=raw \
  -device virtio-blk-device,drive=data \
  -drive if=none,id=meta,file=/data/local/tmp/meta.img,format=raw \
  -device virtio-blk-device,drive=meta \
  -no-reboot -display none -monitor none -serial file:/data/local/tmp/g14.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 130
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 行数 ==="
  wc -l /data/local/tmp/g14.log
  echo "=== 关键行 ==="
  grep -nE 'vda|vdb|vdc|vdd|by-name|metadata|Failed to mount|InitFatalReboot|logd|zygote|SystemServer|BootAnimation|Reboot failed' /data/local/tmp/g14.log | tail -40
  echo "=== tail 20 ==="
  tail -20 /data/local/tmp/g14.log
} > /data/local/tmp/exp14.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> /data/local/tmp/exp14.txt
