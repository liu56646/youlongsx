#!/system/bin/sh
# 实验 20：在物理分区方案上挂探针，rdinit=/dumper，观察二阶段 init 卡在哪
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
cd /dev/vexp || exit 1
pkill -9 qemu-system-aarch64 2>/dev/null
sleep 2
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
export VMHOST_CO_TRACE=1
rm -f $P/g20.log
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
  -no-reboot -display none -monitor none -serial file:$P/g20.log \
  < /dev/null > /dev/null 2>$P/g20.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 180
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 启动进度：每轮 [汇总]（共 $(grep -ac '\[汇总\]' $P/g20.log) 轮）==="
  grep -a '\[汇总\]' $P/g20.log
  echo "=== init 到底卡在打开哪个文件（>>> 行，最后 14 行）==="
  grep -aE 'DUMP: >>>' $P/g20.log | tail -14
  echo "=== /proc/1 关键链接 cwd/root/exe/fd（最后 8 行）==="
  grep -aE 'DUMP: /proc/1/(cwd|root|exe|fd) ' $P/g20.log | tail -8
  echo "=== init 关键行 ==="
  grep -naE 'init:|setns|Switching root|Failed|abort' $P/g20.log | tail -20
  echo "=== 行数 ==="
  wc -l $P/g20.log
  echo "=== qemu stderr 里的 COTRACE 尾部（最后 24 行）==="
  grep -a COTRACE $P/g20.err | tail -24
  echo "=== qemu stderr 头部（前 6 行）==="
  head -6 $P/g20.err 2>/dev/null
} > $P/exp20.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp20.txt
