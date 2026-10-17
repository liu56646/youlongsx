#!/system/bin/sh
#
# 在设备上启动一个虚拟机实例（调试用）。
#
# 两个必须遵守的前提，都踩过坑：
#
# 1) 必须以 shell 身份执行（`adb shell sh /data/local/tmp/start_vm.sh`），
#    **不能**经 run-as 跑整条脚本。因为 am start 会带上调用方包名
#    com.android.shell，与 run-as 切换后的应用 uid 不匹配，直接报
#      Permission Denial: package=com.android.shell does not belong to uid=10340
#    文件操作则相反，必须经 run-as 才能写应用私有目录 —— 所以脚本里混用两者。
#
# 2) 必须把命令写成**文件**再执行，不能内联成
#      adb shell "am start ... --es KEY '{\"a\":1}'"
#    那条链路要穿 PowerShell → adb.exe → 设备 sh 三层转义，JSON 的双引号
#    会在某一层被吃掉，native 侧拿到的是没有引号的 "{a:1}"，取值直接失败。
#    文件 push 上去字节原样保留，谁都不会改。
#
# 用法：
#   adb push start_vm.sh /data/local/tmp/
#   adb shell sh /data/local/tmp/start_vm.sh [imageTag] [netMode] [cores] [vmId]
#
TAG="${1:-p11_arm64}"
NET="${2:-NAT}"
# vCPU 数。实测 guest 的关键路径（system_server / SurfaceFlinger / launcher 主线程）
# 是单线程串行的，多给 vCPU 用不上，反而有 MTTCG 抢锁和 idle vCPU 被定时器唤醒的开销，
# 所以留一个参数方便做 1/2/4 的对比实验。
CORES="${3:-4}"
# 实例号：决定数据目录与拉起哪个实例进程（VmNativeActivity<N>）。默认 1。
VMID="${4:-1}"
# 访客显示分辨率（运行期可调，见 vm_qemu.c 的 VMHOST_GFX_W/H）。
# TCG 下像素量直接决定合成耗时，留成参数便于 A/B 对比。
W="${5:-720}"
H="${6:-1280}"

APP=com.vm.app
BASE=/data/user/0/$APP/files
DATA=$BASE/vms/vm_$VMID

# --- 实例数据盘 ---------------------------------------------------------
# Android 的 /data 必须是已格式化的分区，用镜像里的 userdata.img 当模板，
# 再稀疏扩容；直接给全零文件访客会卡在挂载 /data。
run-as $APP mkdir -p files/vms/vm_$VMID/logs

if ! run-as $APP test -f files/vms/vm_$VMID/userdata.img; then
    echo "创建数据盘：以 $TAG/userdata.img 为模板"
    run-as $APP cp "files/images/$TAG/userdata.img" files/vms/vm_$VMID/userdata.img
    run-as $APP truncate -s 4G files/vms/vm_$VMID/userdata.img
fi

# --- 启动 ---------------------------------------------------------------
CONFIG="{\"vmId\":$VMID,\"width\":$W,\"height\":$H,\"dpi\":320,\"memoryMb\":3072,\"cores\":$CORES,\"gpuMode\":\"GLES\",\"netMode\":\"$NET\",\"imageDir\":\"$BASE/images/$TAG\",\"dataDir\":\"$DATA\"}"

echo "image = $BASE/images/$TAG"
echo "data  = $DATA"

am start -n $APP/.instance.VmNativeActivity$VMID --es com.vm.core.extra.CONFIG "$CONFIG"
