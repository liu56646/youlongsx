#!/system/bin/sh
# 把轻量崩溃捕获库挂进 zygote（zygote 崩、以及它 fork 出的子进程崩，都会记到
# /metadata/crash.log；库本身是惰性的，不崩就什么都不做）
#
# 注：曾试过加 -Xverify:none（想省掉类校验），实测**反而慢 2~3x**：
#   SystemServerTiming: StartPackageManagerService = 168s（有校验时 ~55s）
#   StartActivityManager = 9.8~12s（有校验时 ~6.4s）
#   —— ART 对未校验的类不做 JIT 编译，全走解释器。已回退。
export LD_PRELOAD=/system/lib64/libcrashlite.so
exec /system/bin/app_process64 -Xzygote /system/bin --zygote --start-system-server
