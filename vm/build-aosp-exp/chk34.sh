#!/system/bin/sh
P=/data/local/tmp
echo "--- exp34.txt ---"
head -10 $P/exp34.txt 2>/dev/null
echo "--- qemu alive ---"
ps -A | grep -c '[q]emu-system'
echo "--- guest last time ---"
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g34.log | tail -1
echo "--- HWC / SF / system_server / boot ---"
grep -aE "starting service 'surfaceflinger'|hwcomposer-2-3|system_server|boot_completed|starting service 'zygote'" $P/g34.log | tail -10
echo "--- crash log lines ---"
wc -l $P/qemu_crash.log 2>/dev/null
