#!/system/bin/sh
# D1a 验证脚本（临时）：新 QEMU（含 gfxstream 截图回传）+ VMHOST_FRAME_DIR。
# 截图线程轮询 $VMHOST_FRAME_DIR/frame.request（内容 "宽 高"），
# 有请求就写 frame.ppm（最新一帧，缩放）并自增 frame.seq。
# D1d：guest 改走 goldfish pipe（默认），不再用 virtio-gpu 传输 ——
#   guest 的 DRM 核心未初始化（/sys/class/drm 不存在），virtio-gpu probe 必失败；
#   hwcomposer 经 goldfish pipe 连 host 的 opengles 服务即可，绕开 virtio-gpu。
P=/data/local/tmp
K=/data/user/0/com.vm.app/files/images/p11_arm64/kernel
mkdir -p $P/frames
rm -f $P/frames/frame.*
export LD_LIBRARY_PATH=/dev/vexp
export VMHOST_FRAME_DIR=$P/frames
# 注：不设 VMHOST_VIRTIO_GPU（goldfish pipe 直传模式，默认 recv_mode）
export VMHOST_CRASH_CAPTURE=1
export VMHOST_GFX_DEBUG=1
# D1g：补下发 lcd_density（guest SF 报 ro.sf.lcd_density must be defined）。
# 标准 emulator 的 boot-properties 会下发 qemu.sf.lcd_density，guest 据此设 ro.sf.lcd_density。
export VMHOST_BOOT_PROPS="qemu.hw.mainkeys=0;qemu.adb.secure=0;ro.kernel.qemu.opengles.version=196610;qemu.sf.lcd_density=320;ro.sf.lcd_density=320"
exec /dev/vexp/qemu-system-aarch64 \
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
