#!/system/bin/sh
P=/data/local/tmp
echo "--- qemu alive ---"
ps -A | grep -c '[q]emu-system'
echo "--- guest last time ---"
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g36.log | tail -1
echo "--- 启动里程碑 ---"
grep -aE "starting service 'surfaceflinger'|starting service 'zygote'|starting service 'system_server'|boot_completed|Boot completed|bootanim|starting service 'vendor.hwcomposer" $P/g36.log | tail -12
echo "--- 任何 abort / signal 6 ---"
grep -aE "received signal 6|Aborted|Fatal signal" $P/g36.log | tail -6
echo "--- 最后 8 行 ---"
tail -8 $P/g36.log
