#!/system/bin/sh
# 实验 26：主动采样 HWC 用户态回溯（hwcbt 服务 + debuggerd -b），
# 经 stdio_to_kmsg 进串口。相比 exp25 只改：system.img 换成注入了 hwcbt 的版本，
# 输出改 g26。
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
cd /dev/vexp || exit 1
pkill -9 qemu-system-aarch64 2>/dev/null
sleep 2
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
export VMHOSTPIPE_SVC=1
export ANDROID_EMUGL_VERBOSE=1
export VMHOST_BOOT_PROPS="qemu.hw.mainkeys=0;qemu.adb.secure=0;ro.kernel.qemu.opengles.version=196610;persist.logd.logpersistd=logcatd"
unset VMHOST_CO_TRACE
rm -f $P/g26.log $P/g26.err $P/g26.out
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
  -no-reboot -display none -monitor none -serial file:$P/g26.log \
  < /dev/null > $P/g26.out 2>$P/g26.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 240
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== hwcbt 服务是否启动 ==="
  grep -aE "starting service 'hwcbt'|hwcbt" $P/g26.log | head -10
  echo "=== HWC 时间线 ==="
  grep -aE "hwcomposer-2-3|received signal" $P/g26.log | head -20
  echo "=== HWCBT 采样统计 ==="
  echo "sampler-start=$(grep -ac 'sampler start' $P/g26.log)"
  echo "samples=$(grep -ac 'HWCBT: ===== sample n=' $P/g26.log)"
  echo "sample-ends=$(grep -ac 'sample-end' $P/g26.log)"
  echo "=== HWCBT 前 60 行 ==="
  grep -aE 'HWCBT|debuggerd|tombstoned|ptrace|backtrace' $P/g26.log | head -60
} > $P/exp26.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp26.txt
