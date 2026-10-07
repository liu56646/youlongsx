#!/system/bin/sh
# 自检：preload + VMHOST_CRASH_TEST 下 handler 是否正常工作
P=/data/local/tmp
export LD_LIBRARY_PATH=/dev/vexp
export LD_PRELOAD=$P/libsigfix.so
export VMHOST_CRASH_CAPTURE=1
export VMHOST_CRASH_TEST=1
rm -f $P/qemu_crash.txt
/dev/vexp/qemu-system-aarch64 -M ranchu -cpu cortex-a57 -smp 1 -m 512 -display none -monitor none -serial none
echo "TEST_EXIT=$?" > $P/crash_test_exit2.log
