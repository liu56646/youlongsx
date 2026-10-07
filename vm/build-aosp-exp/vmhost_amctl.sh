#!/system/bin/sh
# VMHost · 方案 2：在 guest 内注册 IActivityController，让 system_server 的 Watchdog
# 检测到「系统卡死」时只回调、不 SIGKILL（详见 AmController.java）。
# app_process 自带 binder 线程池（AppRuntime::onStarted -> startThreadPool），
# BOOTCLASSPATH 由 init 的全局环境提供（init.environ.rc）。
export CLASSPATH=/system/framework/vmhost_amctl.jar
exec app_process /system/bin --nice-name=vmhost_amctl vmhost.AmController
