#!/system/bin/sh
# VMHost 调试 wrapper：
#   1) 先把 HWC 自己的 pid 写出来（采样器 O(1) 拿到，exec 后 pid 不变）
#   2) LD_PRELOAD 挂崩溃捕获库，SIGABRT 瞬间直接落回溯（绕开坏掉的 crash_dump）
echo $$ > /metadata/hwc.pid 2>/dev/null
echo $$ > /data/system/hwc.pid 2>/dev/null
export LD_PRELOAD=/vendor/lib64/libhwcdbg.so
exec /vendor/bin/hw/android.hardware.graphics.composer@2.3-service
