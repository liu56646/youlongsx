#!/system/bin/sh
# 诊断 3：逐线程 CPU 增量，判断卡住是访客 vCPU 在跑还是宿主线程死循环
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp
rm -f /data/local/tmp/g14.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 1 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -display none -monitor none -serial file:/data/local/tmp/g14.log \
  < /dev/null > /dev/null 2>&1 &
QPID=$!
echo "QPID=$QPID"
sleep 60

snap() {
    L=$1
    for f in /proc/$QPID/task/*/stat; do
        tid=$(basename $(dirname "$f"))
        awk -v t="$tid" -v l="$L" '{ print l, t, $14+$15, $3 }' "$f"
    done
}

snap A >  /data/local/tmp/diag3.txt 2>&1
sleep 5
snap B >> /data/local/tmp/diag3.txt 2>&1
echo "--- guest tail ---" >> /data/local/tmp/diag3.txt
tail -3 /data/local/tmp/g14.log >> /data/local/tmp/diag3.txt 2>&1
kill -9 $QPID 2>/dev/null
echo DONE >> /data/local/tmp/diag3.txt
