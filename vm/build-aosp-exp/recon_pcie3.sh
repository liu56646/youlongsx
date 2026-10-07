#!/usr/bin/env bash
Q=/root/vmbuild/qemu-aosp
echo "=== arm-softmmu.mak 里 PCI/GOLDFISH/GPEX/VIRT 全部相关行 ==="
grep -nE 'CONFIG_(PCI|GOLDFISH|GPEX|ARM_VIRT|VIRTIO|MSI)' "$Q/default-configs/arm-softmmu.mak"
echo
echo "=== 构建产物里有没有这些 .o ==="
find "$Q" -name 'goldfish_address_space.o' -o -name 'gpex.o' -o -name 'android_address_space_device.o' -o -name 'qemu-setup.o' 2>/dev/null | head -20
echo
echo "=== build_qemu_aosp.sh 的 configure / 目标 ==="
grep -nE 'configure|--target-list|--enable-|--disable-|make |make -j|ninja' /mnt/k/youlongsx/vm/engine/scripts/build_qemu_aosp.sh | head -40
echo
echo "=== 现有二进制里是否已链接这些符号 ==="
BIN=$(find /mnt/k/youlongsx/vm/engine/src/main/cpp/prebuilt/qemu-aosp/arm64-v8a -name 'qemu-system-aarch64' 2>/dev/null | head -1)
echo "BIN=$BIN"
if [ -n "$BIN" ]; then
  NM=/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm
  "$NM" "$BIN" 2>/dev/null | grep -iE 'goldfish_address_space_set_service_ops|qemu_android_address_space_device_init|address_space_set_hw_funcs|gpex' | head -20
fi
