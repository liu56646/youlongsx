#!/system/bin/sh
# 实验 43：修复 EventHub "/dev/input 不存在 -> LOG_ALWAYS_FATAL" 后重跑。
#   - 新增 /system/etc/init/vmhost_input.rc（mkdir /dev/input 0775 root input）
#   - crashlite raise() 假死 bug 已修（崩溃不再伪装成 clean exit(1)）
# 预期：system_server 越过 StartInputManagerService -> StartWindowManagerService -> ... -> sys.boot_completed=1
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
rm -f $P/g43.log $P/g43.err $P/g43.out $P/exp43.txt
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
  -no-reboot -display none -monitor none -serial file:$P/g43.log \
  < /dev/null > $P/g43.out 2>$P/g43.err &
QPID=$!
echo "QPID=$QPID" > $P/exp43.txt
# 每 60s 把进度与 boot_completed 记到 exp43.txt，便于外部盯
(
  i=0
  while kill -0 $QPID 2>/dev/null; do
    i=$((i+60))
    if [ -f $P/g43.log ]; then
      BC=$(grep -ac 'sys.boot_completed=1' $P/g43.log 2>/dev/null)
      LAST=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g43.log 2>/dev/null | tail -1)
      echo "t=${i}s guest=${LAST} boot_completed=${BC} alive=1" >> $P/exp43.txt
      [ "$BC" != "0" ] && echo " BOOT_COMPLETED_HIT" >> $P/exp43.txt
    else
      echo "t=${i}s no-log-yet alive=1" >> $P/exp43.txt
    fi
    sleep 60
  done
) &

wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g43.log | tail -1)"
  echo "JNI_FatalError_count=$(grep -ac 'JNI FatalError' $P/g43.log)"
  echo "boot_completed=$(grep -ac 'sys.boot_completed=1' $P/g43.log)"
} >> $P/exp43.txt 2>&1
echo DONE >> $P/exp43.txt
