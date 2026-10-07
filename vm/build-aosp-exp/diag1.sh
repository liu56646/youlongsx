#!/system/bin/sh
# 诊断：QEMU 卡住时，逐线程看 CPU 累积，判断是访客 vCPU 空转还是宿主线程空转
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
cd /dev/vexp || exit 1
cp -f /data/local/tmp/vmaosp/* /dev/vexp/ 2>/dev/null
chmod 755 /dev/vexp/qemu-system-aarch64 /dev/vexp/*.so 2>/dev/null
export LD_LIBRARY_PATH=/dev/vexp

rm -f /data/local/tmp/diag1.log
/dev/vexp/qemu-system-aarch64 \
  -M ranchu -cpu cortex-a57 -smp 4 -m 2048 \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled" \
  -drive if=none,id=system,file="$IMG/system.img",format=raw,readonly=on \
  -device virtio-blk-device,drive=system \
  -no-reboot -nographic > /data/local/tmp/diag1.guest 2>&1 &
QPID=$!
echo "QPID=$QPID"
sleep 100

dump_threads() {
    T=$1
    LBL=$2
    for d in /proc/$T/task/*; do
        n=$(cat "$d/comm" 2>/dev/null)
        s=$(cat "$d/stat" 2>/dev/null)
        rest=${s#*) }
        set -- $rest
        echo "$LBL tid=$(basename $d) name=$n utime=$12 stime=$13"
    done
}

dump_threads $QPID A >> /data/local/tmp/diag1.log 2>&1
sleep 5
dump_threads $QPID B >> /data/local/tmp/diag1.log 2>&1
echo "--- guest tail ---" >> /data/local/tmp/diag1.log
tail -3 /data/local/tmp/diag1.guest >> /data/local/tmp/diag1.log 2>&1
kill -9 $QPID 2>/dev/null
