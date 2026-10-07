#!/system/bin/sh
# 实验 44：在 exp43 基础上加两个「提速」项，目标是熬过 Watchdog 硬编码的 60s：
#   1) 所有 virtio-blk 加 cache=unsafe —— 跳过写屏障/fsync（TCG 上 Android 的 fsync 很贵，
#      上次看门狗就是卡在 java.io.UnixFileSystem.normalize 这类文件 I/O 上）。
#   2) -smp 4 -> 6（宿主 8 核）。
# 其它与 exp43 相同：/dev/input 修复、crashlite、预置 runtime-permissions.xml（跳过权限升级）、
# zygote 无 -Xverify（保留 JIT）。
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
rm -f $P/g44.log $P/g44.err $P/g44.out $P/exp44.txt
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 6 -m 2048 \
  -kernel "$IMG/kernel" -initrd $P/ramdisk_probe.img \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 rdinit=/dumper ignore_loglevel panic=0 printk.devkmsg=on audit=0" \
  -drive if=none,id=data,file=$P/data.img,format=raw,cache=unsafe \
  -drive if=none,id=metadata,file=$P/meta.img,format=raw,cache=unsafe \
  -drive if=none,id=system_ext,file=$P/system_ext.img,format=raw,readonly=on,cache=unsafe \
  -drive if=none,id=product,file=$P/product.img,format=raw,readonly=on,cache=unsafe \
  -drive if=none,id=vendor,file=$P/vendor.img,format=raw,readonly=on,cache=unsafe \
  -drive if=none,id=system,file=$P/system.img,format=raw,readonly=on,cache=unsafe \
  -device virtio-blk-device,drive=data \
  -device virtio-blk-device,drive=metadata \
  -device virtio-blk-device,drive=system_ext \
  -device virtio-blk-device,drive=product \
  -device virtio-blk-device,drive=vendor \
  -device virtio-blk-device,drive=system \
  -device virtio-rng-device \
  -device virtio-gpu-device \
  -no-reboot -display none -monitor none -serial file:$P/g44.log \
  < /dev/null > $P/g44.out 2>$P/g44.err &
QPID=$!
echo "QPID=$QPID" > $P/exp44.txt
(
  i=0
  while kill -0 $QPID 2>/dev/null; do
    i=$((i+60))
    if [ -f $P/g44.log ]; then
      BC=$(grep -ac 'sys.boot_completed=1' $P/g44.log 2>/dev/null)
      LAST=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g44.log 2>/dev/null | tail -1)
      echo "t=${i}s guest=${LAST} boot_completed=${BC} alive=1" >> $P/exp44.txt
      [ "$BC" != "0" ] && echo " BOOT_COMPLETED_HIT" >> $P/exp44.txt
    else
      echo "t=${i}s no-log-yet alive=1" >> $P/exp44.txt
    fi
    sleep 60
  done
) &

wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g44.log | tail -1)"
  echo "JNI_FatalError_count=$(grep -ac 'JNI FatalError' $P/g44.log)"
  echo "boot_completed=$(grep -ac 'sys.boot_completed=1' $P/g44.log)"
} >> $P/exp44.txt 2>&1
echo DONE >> $P/exp44.txt
