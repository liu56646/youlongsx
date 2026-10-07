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
#   adb shell sh /data/local/tmp/start_vm.sh [imageTag] [netMode]
#
TAG="${1:-p11_arm64}"
NET="${2:-NAT}"

APP=com.vm.app
BASE=/data/user/0/$APP/files
DATA=$BASE/vms/vm_1

# --- 实例数据盘 ---------------------------------------------------------
# Android 的 /data 必须是已格式化的分区，用镜像里的 userdata.img 当模板，
# 再稀疏扩容；直接给全零文件访客会卡在挂载 /data。
run-as $APP mkdir -p files/vms/vm_1/logs

if ! run-as $APP test -f files/vms/vm_1/userdata.img; then
    echo "创建数据盘：以 $TAG/userdata.img 为模板"
    run-as $APP cp "files/images/$TAG/userdata.img" files/vms/vm_1/userdata.img
    run-as $APP truncate -s 4G files/vms/vm_1/userdata.img
fi

# --- 启动 ---------------------------------------------------------------
CONFIG="{\"vmId\":1,\"width\":720,\"height\":1280,\"dpi\":320,\"memoryMb\":2048,\"cores\":4,\"gpuMode\":\"GLES\",\"netMode\":\"$NET\",\"imageDir\":\"$BASE/images/$TAG\",\"dataDir\":\"$DATA\"}"

echo "image = $BASE/images/$TAG"
echo "data  = $DATA"

am start -n $APP/.instance.VmNativeActivity1 --es com.vm.core.extra.CONFIG "$CONFIG"
