#!/system/bin/sh
P=/data/local/tmp
echo "--- g26.log ---"
ls -la $P/g26.log 2>&1
echo "--- hwcbt service ---"
grep -aE "hwcbt" $P/g26.log 2>/dev/null | head -8
echo "--- kmsg sample markers ---"
grep -ac 'HWCBT: sample ' $P/g26.log 2>/dev/null
grep -aE 'HWCBT: sample ' $P/g26.log 2>/dev/null | tail -3
echo "--- HWC ---"
grep -aE 'hwcomposer-2-3' $P/g26.log 2>/dev/null | head -4
echo "--- last time ---"
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g26.log 2>/dev/null | tail -1
