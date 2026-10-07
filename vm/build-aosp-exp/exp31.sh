#!/system/bin/sh
# 实验 31：抓 qemu 的死因。
#   - wait $QPID 精确拿到退出码（>128 表示被信号杀掉）
#   - 全程落一份宿主 logcat（main/system/events/crash），事后 grep 谁发的 kill
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
rm -f $P/g31.log $P/g31.err $P/g31.out $P/host_lc.txt $P/exp31.txt

logcat -b main,system,events,crash -v threadtime > $P/host_lc.txt 2>&1 &
LCPID=$!
echo "LCPID=$LCPID" > $P/exp31.txt

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
  -no-reboot -display none -monitor none -serial file:$P/g31.log \
  < /dev/null > $P/g31.out 2>$P/g31.err &
QPID=$!
echo "QPID=$QPID" >> $P/exp31.txt
( sleep 400; kill -0 $QPID 2>/dev/null && echo "STILL_ALIVE_AFTER_400s" >> $P/exp31.txt ) &

wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g31.log | tail -1)"
  echo "boot_count=$(grep -ac 'Booting Linux' $P/g31.log)"
  echo "=== logcat: qemu / kill / lmkd / am_kill ==="
  grep -aiE 'qemu|lmkd|lowmemory|am_kill|kill|died|SIGKILL|signal 9' $P/host_lc.txt | tail -60
} >> $P/exp31.txt 2>&1
kill -9 $LCPID 2>/dev/null
echo DONE >> $P/exp31.txt
