#!/system/bin/sh
# 实验 30：验证「宿主 LMK 杀掉 qemu」假设。
# 与 exp26 相同，但启动后立刻把 qemu 的 oom_score_adj 设为 -1000（免疫 LMK），窗口 420s。
# 若这次能存活，就说明之前是被 LMK 杀的。
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
rm -f $P/g30.log $P/g30.err $P/g30.out
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
  -no-reboot -display none -monitor none -serial file:$P/g30.log \
  < /dev/null > $P/g30.out 2>$P/g30.err &
QPID=$!
# 免疫 LMK
echo -1000 > /proc/$QPID/oom_score_adj 2>/dev/null
echo "oom_score_adj=$(cat /proc/$QPID/oom_score_adj 2>/dev/null)" >> $P/g30.log
{
  echo "QPID=$QPID"
  sleep 420
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== HWC / SF ==="
  grep -aE "hwcomposer-2-3|starting service 'surfaceflinger'" $P/g30.log | head -10
  echo "=== received signal ==="
  grep -aE "received signal" $P/g30.log | head -10
  echo "=== last time ==="
  grep -aoE "^\[ *[0-9]+\.[0-9]+\]" $P/g30.log | tail -1
  echo "=== boot count ==="
  grep -ac 'Booting Linux' $P/g30.log
} > $P/exp30.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp30.txt
