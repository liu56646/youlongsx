#!/system/bin/sh
# 验证 preload 是否真的解除线程 SEGV 屏蔽
P=/data/local/tmp
export LD_LIBRARY_PATH=/dev/vexp
export LD_PRELOAD=$P/libsigfix.so
setsid /dev/vexp/qemu-system-aarch64 -M ranchu -cpu cortex-a57 -smp 1 -m 512 -display none -monitor none -serial none > $P/preload_test2.log 2>&1 < /dev/null &
sleep 3
QPID=$(ps -A | awk '/qemu-system/ {print $2; exit}')
echo "pid=$QPID"
for t in /proc/$QPID/task/*; do
  tid=$(basename $t)
  sb=$(grep '^SigBlk:' $t/status 2>/dev/null)
  echo "tid=$tid $sb"
done
kill -9 $QPID 2>/dev/null
