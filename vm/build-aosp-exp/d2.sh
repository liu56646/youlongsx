#!/system/bin/sh
# D2 验证脚本（临时）：起 exp47 样式的 guest + -qmp，供 screendump 用。
P=/data/local/tmp
K=/data/user/0/com.vm.app/files/images/p11_arm64/kernel
export LD_LIBRARY_PATH=/dev/vexp
exec /dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 6 -m 4096 \
  -kernel "$K" -initrd "$P/ramdisk_probe.img" \
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
  -device virtio-rng-device -device virtio-gpu-device \
  -no-reboot -display vnc :1 -monitor none \
  -serial file:$P/d2.log \
  -qmp tcp:127.0.0.1:4444,server,nowait
