#!/system/bin/sh
# 实验 22：修了协程后端之后，看启动能不能越过 /odm/lib64 继续往下走
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
cd /dev/vexp || exit 1
pkill -9 qemu-system-aarch64 2>/dev/null
sleep 2
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
unset VMHOST_CO_TRACE
rm -f $P/g22.log $P/g22.err
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd $P/ramdisk_probe.img \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 rdinit=/dumper ignore_loglevel panic=0 printk.devkmsg=on" \
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
  -device virtio-rng-device \
  -device virtio-gpu-device \
  -no-reboot -display none -monitor none -serial file:$P/g22.log \
  < /dev/null > /dev/null 2>$P/g22.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 240
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 启动进度：每轮 [汇总]（共 $(grep -ac '\[汇总\]' $P/g22.log) 轮）==="
  grep -a '\[汇总\]' $P/g22.log
  echo "=== init 卡点（>>> 行，最后 4 行）==="
  grep -aE 'DUMP: >>>' $P/g22.log | tail -4
  echo "=== qemu stderr（前 4 行）==="
  head -4 $P/g22.err 2>/dev/null
} > $P/exp22.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp22.txt
