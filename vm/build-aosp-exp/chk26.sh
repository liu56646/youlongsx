#!/system/bin/sh
P=/data/local/tmp
cd $P
echo "--- g26.log ---"
ls -la g26.log 2>&1
echo "--- sampler-start count ---"
grep -ac 'sampler start' g26.log 2>/dev/null
echo "--- hwcbt lines ---"
grep -aE 'hwcbt|HWCBT' g26.log 2>/dev/null | head -12
echo "--- samples count ---"
grep -ac 'HWCBT: ===== sample n=' g26.log 2>/dev/null
echo "--- HWC service ---"
grep -aE 'hwcomposer-2-3' g26.log 2>/dev/null | head -6
echo "--- last time ---"
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' g26.log 2>/dev/null | tail -1
echo "--- qemu alive ---"
ps -A 2>/dev/null | grep -c qemu-system
