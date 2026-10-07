#!/system/bin/sh
# 实验 29：判别 guest 是「请求复位/关机」还是「被外部杀掉」。
# 关键：加 -no-reboot -no-shutdown —— guest 请求复位/关机时 QEMU 会暂停并保持存活；
#       若窗口结束时 QEMU 已消失，则说明是外部 kill / QEMU 自己崩。
# 窗口 300s（够越过 SF 启动点）。
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
rm -f $P/g29.log $P/g29.err $P/g29.out
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
  -no-reboot -no-shutdown \
  -monitor none -display none -serial file:$P/g29.log \
  < /dev/null > $P/g29.out 2>$P/g29.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 300
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE(说明 guest 请求了复位/关机，QEMU 被暂停)"; else echo "STATUS=EXITED(说明是外部 kill 或 QEMU 崩)"; fi
  echo "=== HWC / SF ==="
  grep -aE "hwcomposer-2-3|starting service 'surfaceflinger'" $P/g29.log | head -10
  echo "=== last time ==="
  grep -aoE "^\[ *[0-9]+\.[0-9]+\]" $P/g29.log | tail -1
} > $P/exp29.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp29.txt
