#!/system/bin/sh
# D1c 分离启动器：setsid 独立会话 + 捕获退出码。
# 用法：adb shell "su -c 'sh /data/local/tmp/d1c_detach.sh'"
P=/data/local/tmp
ps -A | grep -q qemu-system && { echo "已有 QEMU 在运行，先杀掉"; pkill -9 qemu-system-aarch64; sleep 1; }
rm -f $P/frames/frame.* $P/d1a_exit.log
setsid sh $P/d1c.sh > $P/d1a_run.log 2>&1 < /dev/null &
echo "已分离启动 QEMU(d1c)，pid=$!；退出码将写入 $P/d1a_exit.log"
