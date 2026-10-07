#!/system/bin/sh
# 排障用：只让 QEMU 生成设备树并 dump 出来（dumpdtb 后 QEMU 立即退出，不真正启动 guest）。
# 目的是看 ranchu 到底给 guest 生成了几个 virtio-mmio 节点、各自的 reg / interrupts。
P=/data/local/tmp
K=/data/user/0/com.vm.app/files/images/p11_arm64/kernel
export LD_LIBRARY_PATH=/dev/vexp
rm -f $P/ranchu.dtb
/dev/vexp/qemu-system-aarch64 \
  -M ranchu,dumpdtb=$P/ranchu.dtb \
  -cpu cortex-a57 -smp 6 -m 4096 \
  -kernel "$K" \
  -initrd "$P/ramdisk_probe.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.hardware.gltransport=virtio-gpu-pipe androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 rdinit=/dumper" \
  -drive if=none,id=data,file=$P/data.img,format=raw,cache=unsafe \
  -drive if=none,id=system,file=$P/system.img,format=raw,readonly=on,cache=unsafe \
  -device virtio-gpu-device,xres=1080,yres=1920 \
  -device virtio-blk-device,drive=data \
  -device virtio-blk-device,drive=system \
  -device virtio-rng-device \
  -display none -monitor none -serial none
echo "exit=$?"
ls -la $P/ranchu.dtb
