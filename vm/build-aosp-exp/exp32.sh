#!/system/bin/sh
# 实验 32：抓 QEMU(SIGSEGV) 的宿主侧回溯。
#   LD_PRELOAD=/data/local/tmp/libqemucrash.so -> 崩时写 /data/local/tmp/qemu_crash.log
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
cd /dev/vexp || exit 1
pkill -9 -f qemu-system-aarch64 2>/dev/null
sleep 2
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
export LD_PRELOAD=$P/libqemucrash.so
export VMHOSTPIPE_SVC=1
export ANDROID_EMUGL_VERBOSE=1
export VMHOST_BOOT_PROPS="qemu.hw.mainkeys=0;qemu.adb.secure=0;ro.kernel.qemu.opengles.version=196610;persist.logd.logpersistd=logcatd"
unset VMHOST_CO_TRACE
rm -f $P/g32.log $P/g32.err $P/g32.out $P/qemu_crash.log $P/exp32.txt
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
  -no-reboot -display none -monitor none -serial file:$P/g32.log \
  < /dev/null > $P/g32.out 2>$P/g32.err &
QPID=$!
( sleep 400; kill -0 $QPID 2>/dev/null && echo "STILL_ALIVE_AFTER_400s" >> $P/exp32.txt ) &
wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g32.log | tail -1)"
  echo "boot_count=$(grep -ac 'Booting Linux' $P/g32.log)"
  echo "=== qemu_crash.log (前 60 行) ==="
  head -60 $P/qemu_crash.log 2>/dev/null
  echo "=== crash log 行数 ==="
  wc -l $P/qemu_crash.log 2>/dev/null
} > $P/exp32.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp32.txt
