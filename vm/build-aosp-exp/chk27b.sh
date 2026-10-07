#!/system/bin/sh
P=/data/local/tmp
echo "--- g27.log ---"
ls -la $P/g27.log 2>&1
echo "--- HWC ---"
grep -aE "hwcomposer-2-3|received signal 6" $P/g27.log 2>/dev/null | head -10
echo "--- SF / zygote / system_server / boot ---"
grep -aE "starting service 'surfaceflinger'|starting service 'zygote'|system_server|boot_completed|bootanim" $P/g27.log 2>/dev/null | tail -12
echo "--- last time ---"
grep -aoE '^\[ *[0-9]+\.[0-9]+\]' $P/g27.log 2>/dev/null | tail -1
echo "--- audit suppress? ---"
grep -ac 'audit_backlog' $P/g27.log 2>/dev/null
