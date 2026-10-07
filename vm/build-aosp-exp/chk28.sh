#!/system/bin/sh
P=/data/local/tmp
echo "--- files ---"
ls -la $P/g28.log $P/g28.err $P/exp28.txt 2>&1
echo "--- 启动次数 ---"
grep -ac 'Booting Linux' $P/g28.log 2>/dev/null
echo "--- HWC / SF ---"
grep -aE "hwcomposer-2-3|starting service 'surfaceflinger'" $P/g28.log 2>/dev/null | head -12
echo "--- 复位线索 ---"
grep -aE "Rebooting|Restarting system|reboot|resetting|shutdown|panic" $P/g28.log 2>/dev/null | tail -12
echo "--- last time ---"
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g28.log 2>/dev/null | tail -1
echo "--- qemu alive ---"
ps -A | grep -c '[q]emu-system'
echo "--- exp28.txt ---"
cat $P/exp28.txt 2>/dev/null
