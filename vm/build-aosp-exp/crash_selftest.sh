#!/system/bin/sh
# 崩溃处理器自检：VMHOST_CRASH_TEST=1 会在 vmhost_crash_install 时 raise(SIGSEGV)。
# 若处理器有效，qemu_crash.log 会有新条目；若无效则无。
P=/data/local/tmp
export LD_LIBRARY_PATH=/dev/vexp
rm -f $P/qemu_crash.log
export VMHOST_CRASH_CAPTURE=1
export VMHOST_CRASH_TEST=1
/dev/vexp/qemu-system-aarch64 -M ranchu -cpu cortex-a57 -smp 1 -m 512 -display none -monitor none -serial none
echo "TEST_EXIT=$?" > $P/crash_test_exit.log
