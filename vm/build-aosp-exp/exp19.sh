#!/system/bin/sh
# 实验 19：六个整盘 ext4 接成 vda..vdf，fstab 走显式设备路径
#   vda=system vdb=vendor vdc=product vdd=system_ext vde=metadata vdf=data
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
cd /dev/vexp || exit 1
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f $P/g19.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 2 -m 2048 \
  -kernel "$IMG/kernel" -initrd $P/ramdisk_phys.img \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 ignore_loglevel panic=0 printk.devkmsg=on" \
  -drive if=none,id=data,file=$P/data.img,format=raw \
  -drive if=none,id=metadata,file=$P/meta.img,format=raw \
  -drive if=none,id=system_ext,file=$P/system_ext.img,format=raw,readonly=on \
  -drive if=none,id=product,file=$P/product.img,format=raw,readonly=on \
  -drive if=none,id=vendor,file=$P/vendor.img,format=raw,readonly=on \
  -drive if=none,id=system,file=$P/system.img,format=raw,readonly=on \
  -device virtio-blk-device,drive=data \
  -device virtio-blk-device,drive=metadata \
  -device virtio-blk-device,drive=system_ext \
  -device virtio-blk-device,drive=product \
  -device virtio-blk-device,drive=vendor \
  -device virtio-blk-device,drive=system \
  -no-reboot -display none -monitor none -serial file:$P/g19.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
{
  echo "QPID=$QPID"
  for i in 1 2 3 4 5 6; do
    sleep 50
    echo "t=$((i*50))s lines=$(wc -l < $P/g19.log)" >> $P/exp19.progress
  done
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 盘映射 ==="
  grep -naE 'virtio_blk virtio' $P/g19.log
  echo "=== 关键行 ==="
  grep -naE 'init:|Mounted|mount\(|Failed|by-name|super|logd|zygote|system_server|Booting|BootAnimation|second stage|vold|apexd|Fatal|abort' $P/g19.log | tail -60
  echo "=== 行数 ==="
  wc -l $P/g19.log
  echo "=== tail 25 ==="
  tail -25 $P/g19.log
} > $P/exp19.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp19.txt
