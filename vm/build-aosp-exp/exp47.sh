#!/system/bin/sh
# 实验 47：方案 2 —— 在 guest 内以 root 注册 IActivityController，
# 让 system_server 的 Watchdog 判定「系统卡死」时只回调（systemNotResponding 返回 0）、
# 不再 SIGKILL -> 不再 zygote 自杀重启 -> 让启动一次跑完并稳住。
#
# 交付物（已注入 system.img）：
#   /system/framework/vmhost_amctl.jar  (dex, 类 vmhost.AmController)
#   /system/bin/vmhost_amctl.sh         (wrapper: CLASSPATH + app_process)
#   /etc/init/vmhost_amctl.rc           (service vmhost_amctl, user root, on zygote-start)
#
# 注：cmdline 保留 audit=0。排查阶段曾去掉它以便看到 avc 拒绝，但确认全程 permissive 后
# 拒绝日志会刷出 5000+ 行（串口 I/O 负担 + 挤掉 logd 环缓冲里的关键行），故恢复 audit=0。
#
# 其余同 exp46：/dev/input 修复、crashlite、预置 runtime-permissions.xml、
# zygote 保留类校验、virtio-blk cache=unsafe、-smp 6、-m 4096、削 main 日志。
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
rm -f $P/g47.log $P/g47.err $P/g47.out $P/exp47.txt
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 6 -m 4096 \
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
  -no-reboot -display none -monitor none -serial file:$P/g47.log \
  < /dev/null > $P/g47.out 2>$P/g47.err &
QPID=$!
echo "QPID=$QPID" > $P/exp47.txt
(
  i=0
  while kill -0 $QPID 2>/dev/null; do
    i=$((i+60))
    if [ -f $P/g47.log ]; then
      BC=$(grep -ac 'sys.boot_completed=1' $P/g47.log 2>/dev/null)
      AM=$(grep -ac 'vmhost_amctl' $P/g47.log 2>/dev/null)
      WK=$(grep -ac 'WATCHDOG KILLING' $P/g47.log 2>/dev/null)
      LAST=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g47.log 2>/dev/null | tail -1)
      echo "t=${i}s guest=${LAST} boot_completed=${BC} amctl=${AM} wd_kill=${WK} alive=1" >> $P/exp47.txt
      [ "$BC" != "0" ] && echo " BOOT_COMPLETED_HIT" >> $P/exp47.txt
    else
      echo "t=${i}s no-log-yet alive=1" >> $P/exp47.txt
    fi
    sleep 60
  done
) &

wait $QPID
RC=$?
{
  echo "QEMU_EXIT_RC=$RC"
  echo "guest_last_time=$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g47.log | tail -1)"
  echo "JNI_FatalError_count=$(grep -ac 'JNI FatalError' $P/g47.log)"
  echo "boot_completed=$(grep -ac 'sys.boot_completed=1' $P/g47.log)"
  echo "wd_kill=$(grep -ac 'WATCHDOG KILLING' $P/g47.log)"
  echo "amctl_lines=$(grep -ac 'vmhost_amctl' $P/g47.log)"
} >> $P/exp47.txt 2>&1
echo DONE >> $P/exp47.txt
