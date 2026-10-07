#!/system/bin/sh
# 把轻量崩溃捕获库挂进 iorapd（崩时写 /metadata/crash.log）
export LD_PRELOAD=/system/lib64/libcrashlite.so
exec /system/bin/iorapd
