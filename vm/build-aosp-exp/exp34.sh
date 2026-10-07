#!/system/bin/sh
# 实验 34：崩后立刻 dump 宿主内核/日志，找 SIGSEGV 的内核记录。
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
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
rm -f $P/g34.log $P/g34.err $P/g34.out $P/qemu_crash.log $P/exp34.txt

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
  -no-reboot -display none -monitor none -serial file:$P/g34.log \
  < /dev/null > $P/g34.out 2>$P/g34.err &
QPID=$!
echo "QPID=$QPID" > $P/exp34.txt
( sleep 400; kill -0 $QPID 2>/dev/null && echo "STILL_ALIVE_AFTER_400s" >> $P/exp34.txt ) &

wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g34.log | tail -1)"
  echo "crash_log_lines=$(wc -l < $P/qemu_crash.log 2>/dev/null)"
  echo "=== dmesg 尾部（找 qemu / segfault / signal）==="
  dmesg 2>/dev/null | grep -iaE 'qemu|segfault|signal 11|fault|pc :|SIGSEGV' | tail -30
  echo "=== dmesg 最后 15 行 ==="
  dmesg 2>/dev/null | tail -15
  echo "=== logcat crash buffer ==="
  logcat -b crash -d 2>/dev/null | tail -30
} >> $P/exp34.txt 2>&1
echo DONE >> $P/exp34.txt
