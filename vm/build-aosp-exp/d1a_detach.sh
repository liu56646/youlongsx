#!/system/bin/sh
# D1a 分离启动器：用 setsid 把 QEMU 拉进独立进程组/会话，
# 脱离 adb shell 的 pty（重定向 stdin/stdout/stderr），
# 避免 adb 会话断开时进程组被杀导致 QEMU 静默退出。
# 用法：adb shell "su -c 'sh /data/local/tmp/d1a_detach.sh'"
P=/data/local/tmp
# 清理上一次残留（锁文件）
ps -A | grep -q qemu-system && { echo "已有 QEMU 在运行，先杀掉"; pkill -9 qemu-system-aarch64; sleep 1; }
rm -f $P/frames/frame.*
# setsid + 全重定向 + 后台，脱离 pty
setsid sh $P/d1a.sh > $P/d1a_run.log 2>&1 < /dev/null &
echo "已分离启动 QEMU，pid=$!，日志: $P/d1a_run.log / $P/d1f.log"
