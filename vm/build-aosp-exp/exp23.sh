#!/system/bin/sh
# 实验 23：接上 aemu 宿主侧 pipe 服务之后的首次运行。
# 与 exp22 同一套参数，区别：
#   1) VMHOSTPIPE_SVC=1 -> 打印服务侧（aemu AndroidPipe）ops 调用
#   2) 汇总里额外统计 VMHOSTPIPE（设备侧 MMIO）与 VMHOSTPIPESVC（服务侧）
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
rm -f $P/g23.log $P/g23.err
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
  -no-reboot -display none -monitor none -serial file:$P/g23.log \
  < /dev/null > /dev/null 2>$P/g23.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 270
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 启动进度：最后 8 轮 [汇总]（共 $(grep -ac '\[汇总\]' $P/g23.log) 轮）==="
  grep -a '\[汇总\]' $P/g23.log | tail -8
  echo "=== init 卡点（>>> 行，最后 4 行）==="
  grep -aE 'DUMP: >>>' $P/g23.log | tail -4
  echo "=== 设备侧 MMIO 打点 VMHOSTPIPE 计数 ==="
  grep -ac VMHOSTPIPE $P/g23.err
  echo "=== 服务侧 ops 打点 VMHOSTPIPESVC（全部）==="
  grep -a VMHOSTPIPESVC $P/g23.err | head -60
  echo "=== 服务侧 ops 打点计数 ==="
  grep -ac VMHOSTPIPESVC $P/g23.err
  echo "=== null 桩报错（应为 0）==="
  grep -ac 'Please call goldfish_pipe_set_service_ops' $P/g23.err
  echo "=== qemu stderr 全量（前 40 行）==="
  head -40 $P/g23.err
} > $P/exp23.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp23.txt
