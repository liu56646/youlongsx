#!/system/bin/sh
# 栈采样器：每 2 秒对 QEMU 做一次 debuggerd -b（全部线程栈），
# 只保留最近一次转储，QEMU 死后停止。
# 用法：adb shell "su -c 'sh /data/local/tmp/stk_sampler.sh &'"
P=/data/local/tmp
rm -f $P/stk_latest.txt
while true; do
  QPID=$(ps -A | awk '/qemu-system/ {print $2; exit}')
  if [ -z "$QPID" ]; then
    echo "STOP at $(date +%H:%M:%S): qemu 已退出" >> $P/stk_latest.txt
    break
  fi
  debuggerd -b $QPID > $P/stk_latest.txt 2>&1
  sleep 2
done
