#!/system/bin/sh
# 实验 39：在 exp38 基础上，ramdisk 里预置了 /dev/console + /dev/null，
# 目标：消除 system_server 继承 "(deleted) /dev/console" 导致的
#       ART "JNI FatalError ... Not whitelisted (3)" abort 循环，看 guest 能否走完启动。
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
rm -f $P/g39.log $P/g39.err $P/g39.out $P/exp39.txt
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
  -no-reboot -display none -monitor none -serial file:$P/g39.log \
  < /dev/null > $P/g39.out 2>$P/g39.err &
QPID=$!
echo "QPID=$QPID" > $P/exp39.txt
( sleep 1500; kill -0 $QPID 2>/dev/null && echo "ALIVE_AT_1500s" >> $P/exp39.txt ) &

wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g39.log | tail -1)"
  echo "=== 里程碑 ==="
  grep -aE "starting service '(zygote|surfaceflinger|bootanim|iorapd)'|received signal 6|boot_completed" $P/g39.log | tail -25
  echo "=== JNI FatalError 出现次数 ==="
  grep -ac 'JNI FatalError' $P/g39.log
} >> $P/exp39.txt 2>&1
echo DONE >> $P/exp39.txt
