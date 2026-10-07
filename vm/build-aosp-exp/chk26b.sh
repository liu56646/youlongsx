#!/system/bin/sh
P=/data/local/tmp
echo "=== all hwcbt-related lines ==="
grep -an -E 'hwcbt' $P/g26.log | head -30
echo "=== context around parse ==="
grep -an -A8 'Parsing file /system/etc/init/hwcbt.rc' $P/g26.log | head -40
echo "=== init errors / warnings ==="
grep -an -E 'init:.*(nvalid|not found|could not|ailed|rror|Skipping|denied|no domain)' $P/g26.log | head -40
echo "=== logcatd started? ==="
grep -an -E "starting service 'logcatd'|service logcatd" $P/g26.log | head -5
echo "=== services started (sample) ==="
grep -an "starting service" $P/g26.log | tail -20
