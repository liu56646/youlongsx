#!/system/bin/sh
# VMHost guest 侧「状态记录 + 预建崩溃日志」小工具（root 运行）。
#   - 预建 /metadata/crash.log (0666)：给 LD_PRELOAD 崩溃捕获库（iorapd/zygote/HWC）用
#   - 每 3s 记一行关键属性/负载到 /metadata/hwcbt.log，用于事后定位 guest 状态
LOG=/metadata/hwcbt.log

: > /metadata/hwc_crash.log 2>/dev/null
chmod 0666 /metadata/hwc_crash.log 2>/dev/null
: > /metadata/crash.log 2>/dev/null
chmod 0666 /metadata/crash.log 2>/dev/null
: > /metadata/hwc.pid 2>/dev/null
chmod 0666 /metadata/hwc.pid 2>/dev/null

exec > "$LOG" 2>&1
echo "HWCBT: state logger start"
echo "--- /proc/1/fd（全部，重点看 2/3 是不是 deleted console）---"
ls -l /proc/1/fd 2>&1 | grep -vE '\-> (socket|anon_inode|mnt|pipe|/proc/[0-9]+/)'
echo "--- /dev/console 现状 ---"
ls -l /dev/console /dev/null 2>&1
echo "--- /dev 挂载 ---"
grep -E ' /dev ' /proc/1/mounts 2>&1
echo "--- init 的可执行文件与 root ---"
ls -l /proc/1/exe 2>&1

# 干掉 rdinit 观察者，别抢 CPU
for f in $(grep -la '^dumper' /proc/[0-9]*/comm 2>/dev/null); do
    d=${f#/proc/}
    kill -9 "${d%%/*}" 2>/dev/null
done

i=0
while [ $i -lt 900 ]; do
    P=$(getprop 2>/dev/null | grep -aE 'boot_completed|powerctl|init\.svc\.(surfaceflinger|zygote|system_server|servicemanager|vendor\.hwcomposer-2-3)|iorapd' | tr '\n' ' ')
    echo "T t=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null) | $P"
    i=$((i + 1))
    [ $((i % 6)) -eq 0 ] && sync
    sleep 3
done
sync
