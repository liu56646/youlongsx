#!/system/bin/sh
P=/data/local/tmp
echo "--- exp31.txt ---"
cat $P/exp31.txt 2>/dev/null
echo "--- qemu alive ---"
ps -A | grep -c '[q]emu-system'
echo "--- last guest time ---"
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g31.log | tail -1
echo "--- SF / zygote / system_server / boot ---"
grep -aE "starting service 'surfaceflinger'|system_server|boot_completed|starting service 'zygote'|hwcomposer-2-3" $P/g31.log | tail -10
echo "--- guest 最后 12 行 ---"
tail -12 $P/g31.log
