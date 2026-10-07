#!/system/bin/sh
# 实验 37：追 guest 完整启动 + 抓 zygote/iorapd 崩溃细节。
#   相对 exp34：内核 cmdline 加 audit=0（压掉 AVC 洪泛）；窗口 1200s；
#   system.img 里已把轻量崩溃捕获库挂进 iorapd/zygote（崩时写 /metadata/crash.log）。
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
rm -f $P/g37.log $P/g37.err $P/g37.out $P/exp37.txt
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
  -no-reboot -display none -monitor none -serial file:$P/g37.log \
  < /dev/null > $P/g37.out 2>$P/g37.err &
QPID=$!
echo "QPID=$QPID" > $P/exp37.txt
( sleep 1250; kill -0 $QPID 2>/dev/null && echo "ALIVE_AT_1250s" >> $P/exp37.txt ) &

wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g37.log | tail -1)"
  echo "=== 启动里程碑 ==="
  grep -aE "starting service 'zygote'|starting service 'system_server'|boot_completed|Boot completed|starting service 'surfaceflinger'|starting service 'iorapd'|received signal 6" $P/g37.log | tail -25
} >> $P/exp37.txt 2>&1
echo DONE >> $P/exp37.txt
