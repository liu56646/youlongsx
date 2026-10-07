#!/system/bin/sh
# 实验 27：PCIe + goldfish_address_space 修好后，跑更长的窗口看 guest 能走到哪。
# 与 exp26 差别：窗口 420s；内核 cmdline 加 audit=0（permissive 下 AVC 审计把
# audit backlog 刷爆会丢日志）；输出 g27。
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
rm -f $P/g27.log $P/g27.err $P/g27.out
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
  -no-reboot -display none -monitor none -serial file:$P/g27.log \
  < /dev/null > $P/g27.out 2>$P/g27.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 420
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== HWC 时间线 ==="
  grep -aE "hwcomposer-2-3|received signal" $P/g27.log | head -20
  echo "=== SF / zygote / system_server / boot_completed ==="
  grep -aE "starting service 'surfaceflinger'|starting service 'zygote'|system_server|boot_completed|Boot completed|bootanim" $P/g27.log | tail -25
  echo "=== 任何 abort / signal ==="
  grep -aE "received signal 6|Aborted|Fatal" $P/g27.log | head -20
  echo "=== guest 时间轴末端 ==="
  grep -aoE "^\[ *[0-9]+\.[0-9]+\]" $P/g27.log | tail -1
  echo "=== hwcbt 采样统计 ==="
  echo "samples=$(grep -ac 'HWCBT: sample ' $P/g27.log)"
} > $P/exp27.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp27.txt
