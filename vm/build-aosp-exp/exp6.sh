#!/system/bin/sh
# 实验 6：按前端实证出来的磁盘顺序喂盘，并用带 GPT(metadata+userdata) 的数据盘
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
LOG=/data/local/tmp/exp6.log
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp

gunzip -c /data/local/tmp/userdata_ud.img.gz > /data/local/tmp/ud.img
[ -f /data/local/tmp/cache.img ] || dd if=/dev/zero of=/data/local/tmp/cache.img bs=1M count=16 2>/dev/null

: > "$LOG"
timeout 240 /dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=vendor,file="$IMG/vendor.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=vendor \
  -drive if=none,id=userdata,file=/data/local/tmp/ud.img,format=raw \
  -device virtio-blk-device,drive=userdata \
  -drive if=none,id=cache,file=/data/local/tmp/cache.img,format=raw \
  -device virtio-blk-device,drive=cache \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -no-reboot -nographic >> "$LOG" 2>&1
echo "EXIT=$?" >> "$LOG"
