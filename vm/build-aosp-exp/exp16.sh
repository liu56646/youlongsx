#!/system/bin/sh
# 实验 16：盘映射已对，追查 init 第一阶段之后的静默重启
# 加 ignore_loglevel（打全内核/init 日志）+ panic=0（panic 不重启，直接停在现场）
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g16.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 2 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled ignore_loglevel panic=0" \
  -drive if=none,id=meta,file=/data/local/tmp/meta.img,format=raw \
  -drive if=none,id=data,file=/data/local/tmp/data.img,format=raw \
  -drive if=none,id=vendor,file="$IMG/vendor.img",format=raw,readonly=on \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=meta \
  -device virtio-blk-device,drive=data \
  -device virtio-blk-device,drive=vendor \
  -device virtio-blk-device,drive=system \
  -no-reboot -display none -monitor none -serial file:/data/local/tmp/g16.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 100
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 行数 ==="
  wc -l /data/local/tmp/g16.log
  echo "=== 末尾 45 行 ==="
  tail -45 /data/local/tmp/g16.log
} > /data/local/tmp/exp16.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> /data/local/tmp/exp16.txt
