#!/system/bin/sh
# TCG 调优 A/B：按 App 完全相同的 QEMU 参数手工起一次，额外参数由命令行给。
# 用法: shr /data/local/tmp/mt_ab.sh <日志文件名> [额外 QEMU 参数...]
# 例:   sh /data/local/tmp/mt_ab.sh mt.log -accel tcg,thread=multi
LOGN=$1
SMPS=$2
shift 2
LIBS=/data/app/~~EWlqas_lRdxBn5FAVa1qlA==/com.vm.app-esZXINFWwhGwuAMYnOSdlQ==/lib/arm64
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
VM=/data/user/0/com.vm.app/files/vms/vm_1
LOGF=/data/local/tmp/$LOGN
pkill -9 -f libqemu_exec.so 2>/dev/null
pkill -9 -f qemu-system-aarch64 2>/dev/null
sleep 3
rm -f "$LOGF"
export LD_LIBRARY_PATH=$LIBS
export VMHOSTPIPE_SVC=1
export LD_PRELOAD=$LIBS/libsigfix.so
"$LIBS/libqemu_exec.so" \
  -M ranchu -cpu cortex-a57 -smp $SMPS -m 2048 "$@" \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 rdinit=/dumper ignore_loglevel panic=0 printk.devkmsg=on audit=0" \
  -drive if=none,id=d0data,file="$VM/userdata.img",format=raw,cache=unsafe -device virtio-blk-device,drive=d0data \
  -drive if=none,id=d1meta,file="$VM/metadata.img",format=raw,cache=unsafe -device virtio-blk-device,drive=d1meta \
  -drive if=none,id=d2sext,file="$IMG/system_ext.img",format=raw,readonly=on,cache=unsafe -device virtio-blk-device,drive=d2sext \
  -drive if=none,id=d3prod,file="$IMG/product.img",format=raw,readonly=on,cache=unsafe -device virtio-blk-device,drive=d3prod \
  -drive if=none,id=d4vend,file="$IMG/vendor.img",format=raw,readonly=on,cache=unsafe -device virtio-blk-device,drive=d4vend \
  -drive if=none,id=d5sys,file="$IMG/system.img",format=raw,readonly=on,cache=unsafe -device virtio-blk-device,drive=d5sys \
  -device virtio-rng-device -device virtio-gpu-device \
  -no-reboot -display none -monitor none -serial file:"$LOGF" \
  < /dev/null > /data/local/tmp/q.out 2> /data/local/tmp/q.err &
echo "pid=$! log=$LOGF extra=$*"
