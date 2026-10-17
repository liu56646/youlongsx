#!/system/bin/sh
# Headless 启动测速 harness：按引擎 p11 路径的同一组 QEMU 参数手工拉起一次，
# 用于 A/B 绑核策略、CPU 型号、tb-size 等启动参数，不依赖 app 窗口屏幕常亮。
#
# 用法（root adb shell）：
#   sh /data/local/tmp/ab_boot_headless.sh <pin_mode> <logfile> [memMb] [smp] [cpu] [tb_size]
# 例：
#   sh /data/local/tmp/ab_boot_headless.sh legacy   /data/local/tmp/ab-legacy.log
#   sh /data/local/tmp/ab_boot_headless.sh balanced /data/local/tmp/ab-balanced.log
#
# 指标：串口日志里 `sys.boot_completed=1` 首次出现时的内核时间戳
# （QEMU 虚拟时钟约等于宿主单调时钟，和 wall 实测差 <3%）。
#
# 注意：
# - LIBS 从已安装 APK 的 nativeLibraryDir 推出，重装 APK 后自动跟随。
# - p11 的 system.img 是独立 ext4，必须 VMHOST_DT_FSTAB=none；否则 QEMU 会按
#   legacy 下发 DT fstab，访客 init 找不到 system/vendor，16s 左右 InitFatalReboot。
# - 两侧测试前要恢复同一份 userdata 基线，否则首次 dexopt 会污染对比。
# - 跑之前确保 com.vm.app 已 force-stop，避免两个 QEMU 抢 CPU/磁盘。
MODE=${1:-balanced}
LOGF=$2
MEM=${3:-3072}
SMP=${4:-6}
CPU=${5:-cortex-a57}
TB=${6:-512}
LIBS=${LIBS:-$(dirname "$(pm path com.vm.app | head -1 | sed 's/^package://')")/lib/arm64}
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
VM=/data/user/0/com.vm.app/files/vms/vm_1
pkill -9 -x libqemu_exec.so 2>/dev/null
sleep 2
rm -f "$LOGF" /data/local/tmp/ab.out /data/local/tmp/ab.err
export LD_LIBRARY_PATH=$LIBS
export LD_PRELOAD=$LIBS/libsigfix.so
export VMHOST_PIN_MODE=$MODE
export VMHOST_GFX_DEBUG=0
export VMHOST_GFX_W=720
export VMHOST_GFX_H=1280
export VMHOST_FRAME_DIR=$VM/logs
export VMHOST_SNAP_DIR=$VM
export VMHOST_DT_FSTAB=none
unset VMHOST_SAR VMHOST_GOLDFISH_FB VMHOST_GOLDFISH_GRALLOC VMHOST_GFX_POST
"$LIBS/libqemu_exec.so" \
  -name vmhost,debug-threads=on \
  -accel tcg,thread=multi \
  -tb-size "$TB" \
  -M ranchu -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -kernel "$IMG/kernel" -initrd "$IMG/ramdisk.img" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.veritymode=disabled androidboot.force_normal_boot=1 rdinit=/init ignore_loglevel panic=0 printk.devkmsg=on audit=0" \
  -drive if=none,id=d1data,file="$VM/userdata.img",format=raw,cache=unsafe -device virtio-blk-device,drive=d1data \
  -drive if=none,id=d2meta,file="$VM/metadata.img",format=raw,cache=unsafe -device virtio-blk-device,drive=d2meta \
  -drive if=none,id=d3sext,file="$IMG/system_ext.img",format=raw,readonly=on,cache=unsafe -device virtio-blk-device,drive=d3sext \
  -drive if=none,id=d4prod,file="$IMG/product.img",format=raw,readonly=on,cache=unsafe -device virtio-blk-device,drive=d4prod \
  -drive if=none,id=d5vend,file="$IMG/vendor.img",format=raw,readonly=on,cache=unsafe -device virtio-blk-device,drive=d5vend \
  -drive if=none,id=d6sys,file="$IMG/system.img",format=raw,readonly=on,cache=unsafe -device virtio-blk-device,drive=d6sys \
  -device virtio-rng-device \
  -device virtio-gpu-pci \
  -device virtio-tablet-device \
  -device virtio-keyboard-device \
  -no-reboot -display none -monitor none \
  -serial file:"$LOGF" \
  < /dev/null > /data/local/tmp/ab.out 2> /data/local/tmp/ab.err &
echo "started mode=$MODE pid=$! log=$LOGF mem=$MEM smp=$SMP cpu=$CPU tb=$TB"
