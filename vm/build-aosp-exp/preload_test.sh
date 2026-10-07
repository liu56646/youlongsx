#!/system/bin/sh
# 快速验证 LD_PRELOAD 是否加载：启动 qemu，2 秒后查 maps
P=/data/local/tmp
export LD_LIBRARY_PATH=/dev/vexp
export LD_PRELOAD=$P/libsigfix.so
setsid /dev/vexp/qemu-system-aarch64 -M ranchu -cpu cortex-a57 -smp 1 -m 512 -display none -monitor none -serial none > $P/preload_test.log 2>&1 < /dev/null &
sleep 2
QPID=$(ps -A | awk '/qemu-system/ {print $2; exit}')
echo "pid=$QPID"
grep -c sigfix /proc/$QPID/maps
grep sigfix /proc/$QPID/maps | head -2
echo "=== 日志头 ==="
head -3 $P/preload_test.log
kill -9 $QPID 2>/dev/null
