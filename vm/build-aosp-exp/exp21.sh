#!/system/bin/sh
# 实验 21：开 virtio-blk / virtio 队列 / 通知 的 trace，
# 判断 init 卡住的那次读请求到底有没有到 QEMU、有没有完成。
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
P=/data/local/tmp
cd /dev/vexp || exit 1
pkill -9 qemu-system-aarch64 2>/dev/null
sleep 2
cp -f $P/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
export VMHOST_CO_TRACE=1
rm -f $P/g21.log $P/g21.err
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd $P/ramdisk_probe.img \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 rdinit=/dumper ignore_loglevel panic=0 printk.devkmsg=on" \
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
  -trace events=/data/local/tmp/tevents.txt \
  -no-reboot -display none -monitor none -serial file:$P/g21.log \
  < /dev/null > /dev/null 2>$P/g21.err &
QPID=$!
{
  echo "QPID=$QPID"
  sleep 150
  if kill -0 "$QPID" 2>/dev/null; then echo "STATUS=ALIVE"; else echo "STATUS=EXITED"; fi
  echo "=== 各 trace 事件计数 ==="
  for e in virtio_queue_notify virtio_notify virtio_blk_handle_read virtio_blk_handle_write virtio_blk_req_complete virtio_blk_rw_complete blk_co_preadv blk_co_pwritev; do
    printf "%-28s %s\n" "$e" "$(grep -ac "$e" $P/g21.err)"
  done
  echo "=== trace 尾部 20 行 ==="
  grep -aE 'virtio_|blk_co_' $P/g21.err | tail -20
  echo "=== init 卡点 ==="
  grep -aE 'DUMP: >>>' $P/g21.log | tail -3
  echo "=== 全部协程交接的最后 22 行 ==="
  grep -a COTRACE $P/g21.err | tail -22
  echo "=== 与 virtio 事件交叉的最后 14 行（按文件顺序）==="
  grep -aE 'COTRACE|virtio_blk_handle_read|virtio_blk_req_complete|blk_co_preadv|virtio_notify' $P/g21.err | tail -14
} > $P/exp21.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> $P/exp21.txt
