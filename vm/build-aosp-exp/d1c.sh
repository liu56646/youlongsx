#!/system/bin/sh
# D1c 实验脚本：同 d1a.sh，但不用 exec，捕获 QEMU 退出码到 d1a_exit.log。
# 退出码解读（128+n = 信号 n）：137=SIGKILL 141=SIGPIPE 143=SIGTERM 139=SIGSEGV 134=SIGABRT
P=/data/local/tmp
K=/data/user/0/com.vm.app/files/images/p11_arm64/kernel
mkdir -p $P/frames
rm -f $P/frames/frame.*
export LD_LIBRARY_PATH=/dev/vexp
export VMHOST_FRAME_DIR=$P/frames
export VMHOST_CRASH_CAPTURE=1
export VMHOST_GFX_DEBUG=1
export VMHOST_BOOT_PROPS="qemu.hw.mainkeys=0;qemu.adb.secure=0;ro.kernel.qemu.opengles.version=196610;qemu.sf.lcd_density=320;ro.sf.lcd_density=320"
echo "QEMU_START=$(date +%H:%M:%S)" > $P/d1a_exit.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 6 -m 4096 \
  -kernel "$K" -initrd "$P/ramdisk_probe.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 rdinit=/dumper ignore_loglevel panic=0 printk.devkmsg=on audit=0 initcall_debug" \
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
  -no-reboot -display none -monitor none \
  -serial file:$P/d1f.log
echo "QEMU_EXIT=$? at $(date +%H:%M:%S)" >> $P/d1a_exit.log
