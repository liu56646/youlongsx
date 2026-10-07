#!/system/bin/sh
# 实验 41：dumper 的日志 fd 加了 FD_CLOEXEC（不再把 "(deleted) /dev/console" 泄漏给 init）。
# 预期：system_server 不再被 ART 的 fd 白名单检查判死，guest 有机会走完启动。
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
mkdir -p /dev/vexp
cd /dev/vexp || exit 1
pkill -9 -f qemu-system-aarch64 2>/dev/null
sleep 2
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
export VMHOSTPIPE_SVC=1
export ANDROID_EMUGL_VERBOSE=1
export VMHOST_BOOT_PROPS="qemu.hw.mainkeys=0;qemu.adb.secure=0;ro.kernel.qemu.opengles.version=196610;persist.logd.logpersistd=logcatd"
unset VMHOST_CO_TRACE
rm -f $P/g41.log $P/g41.err $P/g41.out $P/exp41.txt
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd $P/ramdisk_probe.img \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 rdinit=/dumper ignore_loglevel panic=0 printk.devkmsg=on audit=0" \
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
  -no-reboot -display none -monitor none -serial file:$P/g41.log \
  < /dev/null > $P/g41.out 2>$P/g41.err &
QPID=$!
echo "QPID=$QPID" > $P/exp41.txt
( sleep 1400; kill -0 $QPID 2>/dev/null && echo "ALIVE_AT_1400s" >> $P/exp41.txt ) &

wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g41.log | tail -1)"
  echo "JNI_FatalError_count=$(grep -ac 'JNI FatalError' $P/g41.log)"
  echo "=== 里程碑 ==="
  grep -aE "starting service '(zygote|iorapd)'|boot_completed|received signal 6" $P/g41.log | tail -20
} >> $P/exp41.txt 2>&1
echo DONE >> $P/exp41.txt
