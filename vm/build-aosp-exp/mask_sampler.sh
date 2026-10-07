#!/system/bin/sh
# 信号掩码采样器：每 3 秒记录所有线程的 SigBlk（/proc/<pid>/task/*/status），
# 只保留最近一次，QEMU 死后停止。用于确认哪些线程屏蔽了 SIGSEGV。
# 用法：adb shell "su -c 'sh /data/local/tmp/mask_sampler.sh &'"
P=/data/local/tmp
rm -f $P/mask_latest.txt
while true; do
  QPID=$(ps -A | awk '/qemu-system/ {print $2; exit}')
  if [ -z "$QPID" ]; then
    echo "STOP at $(date +%H:%M:%S)" >> $P/mask_latest.txt
    break
  fi
  {
    echo "=== $(date +%H:%M:%S) pid=$QPID ==="
    for t in /proc/$QPID/task/*; do
      tid=$(basename $t)
      sigblk=$(grep '^SigBlk:' $t/status 2>/dev/null)
      sigcgt=$(grep '^SigCgt:' $t/status 2>/dev/null)
      comm=$(cat $t/comm 2>/dev/null)
      echo "tid=$tid $comm $sigblk $sigcgt"
    done
  } > $P/mask_latest.txt
  sleep 3
done
