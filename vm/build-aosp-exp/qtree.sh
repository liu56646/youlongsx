#!/system/bin/sh
# 用 QEMU monitor 的 info qtree，实证 disk -> virtio-mmio 地址的落位规则
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
DATA=/data/user/0/com.vm.app/files/vms/vm_1
mkdir -p /dev/vexp
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 2>/dev/null
chmod 755 /dev/vexp/*.so 2>/dev/null
[ -f /data/local/tmp/cache.img ] || dd if=/dev/zero of=/data/local/tmp/cache.img bs=1M count=16 2>/dev/null
cd /dev/vexp
export LD_LIBRARY_PATH=/dev/vexp
printf 'info qtree\nquit\n' | /dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -m 512 -S -display none -monitor stdio \
  -drive if=none,id=vendor,file="$IMG/vendor.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=vendor \
  -drive if=none,id=userdata,file="$DATA/userdata.img",format=raw \
  -device virtio-blk-device,drive=userdata \
  -drive if=none,id=cache,file=/data/local/tmp/cache.img,format=raw \
  -device virtio-blk-device,drive=cache \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  > /data/local/tmp/qtree.txt 2>&1
echo "EXIT=$?" >> /data/local/tmp/qtree.txt
