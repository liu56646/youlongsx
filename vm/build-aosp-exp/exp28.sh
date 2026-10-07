#!/system/bin/sh
# 实验 28：定位 guest 复位。与 exp26 相同的命令行，但：
#   1) 去掉 -no-reboot —— 若 guest 复位，日志里会出现第二次启动（可区分复位 vs 关机）
#   2) gateway 里的 hwcbt 换成了「状态记录器」，会持续记录 boot/service 状态
# 窗口 420s。
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
rm -f $P/g28.log $P/g28.err $P/g28.out
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
  -monitor none -display none -serial file:$P/g28.log \
  < /dev/null > $P/g28.out 2>$P/g28.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 420
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 启动次数（数 'Booting Linux' / 'Kernel command line'）==="
  echo "booting=$(grep -ac 'Booting Linux' $P/g28.log)"
  echo "=== HWC 时间线 ==="
  grep -aE "hwcomposer-2-3|received signal" $P/g28.log | head -20
  echo "=== SF / 复位线索 ==="
  grep -aE "starting service 'surfaceflinger'|Rebooting|reboot|Restarting system|resetting|shutdown" $P/g28.log | tail -25
  echo "=== guest 时间轴末端 ==="
  grep -aoE "^\[ *[0-9]+\.[0-9]+\]" $P/g28.log | tail -1
} > $P/exp28.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp28.txt
