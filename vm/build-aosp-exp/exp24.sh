#!/system/bin/sh
# 实验 24：打印 pipe 首包（服务名），确认访客在请求哪些管道服务。
# 其余同 exp23，观察窗口缩短到 150s（pipe 活动发生在启动早期）。
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
cd /dev/vexp || exit 1
pkill -9 qemu-system-aarch64 2>/dev/null
sleep 2
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
export VMHOSTPIPE_SVC=1
unset VMHOST_CO_TRACE
rm -f $P/g24.log $P/g24.err
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
  -no-reboot -display none -monitor none -serial file:$P/g24.log \
  < /dev/null > /dev/null 2>$P/g24.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 150
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 服务侧 ops 打点（含首包内容，全部）==="
  grep -a VMHOSTPIPESVC $P/g24.err
  echo "=== 设备侧 MMIO 打点计数 ==="
  grep -ac VMHOSTPIPE $P/g24.err
  echo "=== 未知服务名报错（AndroidPipe 侧）==="
  grep -a 'Unknown server with name' $P/g24.err | sort | uniq -c
} > $P/exp24.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp24.txt
