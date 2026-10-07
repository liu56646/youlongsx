#!/system/bin/sh
# 实验 36：再取 core 定位新的崩溃点。相对 exp35：加 mkdir -p /dev/vexp（宿主重启会清掉），
# 崩后自动截 core 头部，便于拉回解析。
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
mkdir -p /dev/vexp
cd /dev/vexp || exit 1
pkill -9 -f qemu-system-aarch64 2>/dev/null
sleep 2
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
rm -f $P/core.* $P/exp36.txt $P/core_head3.bin
echo /data/local/tmp/core.%p > /proc/sys/kernel/core_pattern 2>/dev/null
ulimit -c unlimited
export LD_LIBRARY_PATH=/dev/vexp
export VMHOSTPIPE_SVC=1
export ANDROID_EMUGL_VERBOSE=1
export VMHOST_BOOT_PROPS="qemu.hw.mainkeys=0;qemu.adb.secure=0;ro.kernel.qemu.opengles.version=196610;persist.logd.logpersistd=logcatd"
unset VMHOST_CO_TRACE
rm -f $P/g36.log $P/g36.err $P/g36.out

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
  -no-reboot -display none -monitor none -serial file:$P/g36.log \
  < /dev/null > $P/g36.out 2>$P/g36.err &
QPID=$!
echo "QPID=$QPID" > $P/exp36.txt
( sleep 400; kill -0 $QPID 2>/dev/null && echo "STILL_ALIVE_AFTER_400s" >> $P/exp36.txt ) &

wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g36.log | tail -1)"
  echo "=== core ==="
  ls -la $P/core.* 2>/dev/null
  echo "=== control ops 接线日志 ==="
  grep -a '控制\|control ops\|hw funcs' $P/g36.err | head -5
} >> $P/exp36.txt 2>&1
# 崩后立刻截 core 头部（notes/phdrs 都在最前面）
CORE=$(ls $P/core.* 2>/dev/null | head -1)
[ -n "$CORE" ] && dd if=$CORE of=$P/core_head3.bin bs=1048576 count=4 2>/dev/null
echo DONE >> $P/exp36.txt
