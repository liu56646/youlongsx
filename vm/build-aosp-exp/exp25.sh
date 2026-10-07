#!/system/bin/sh
# 实验 25：恢复 logd + 打开 logcatd 持久化，抓 HWC 崩溃（abort message / backtrace）。
# 相对 exp24 的差别：
#   1) system.img 已补回 /etc/init/logd.rc（logd 重新可用）
#   2) 通过 VMHOST_BOOT_PROPS 下发 persist.logd.logpersistd=logcatd
#      -> logcatd.rc 的触发器会把日志落到 /data/misc/logd/logcat*
#   3) 观察窗口 170s（要越过 ~107s 的 HWC 崩溃点）
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
cd /dev/vexp || exit 1
pkill -9 qemu-system-aarch64 2>/dev/null
sleep 2
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
export VMHOSTPIPE_SVC=1
# gfxstream 的 EGL/渲染器详细日志（读这个环境变量的地方在 EglOsApi_egl.cpp:341 等）
export ANDROID_EMUGL_VERBOSE=1
# 走我们自己的 boot-properties 服务下发，注意会**整体替换**默认列表，
# 所以三条默认项要一并带上。
export VMHOST_BOOT_PROPS="qemu.hw.mainkeys=0;qemu.adb.secure=0;ro.kernel.qemu.opengles.version=196610;persist.logd.logpersistd=logcatd"
unset VMHOST_CO_TRACE
rm -f $P/g25.log $P/g25.err $P/g25.out
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
  -no-reboot -display none -monitor none -serial file:$P/g25.log \
  < /dev/null > $P/g25.out 2>$P/g25.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 240
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== logd / logcatd 是否起来 ==="
  grep -aE "starting service '(logd|logcatd)'|service logd not found" $P/g25.log | head
  echo "=== HWC 崩溃时间点 ==="
  grep -aE "hwcomposer|received signal" $P/g25.log | head -12
  echo "=== guest 时间轴末端 ==="
  grep -aoE "^\[ *[0-9]+\.[0-9]+\]" $P/g25.log | tail -1
} > $P/exp25.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp25.txt
