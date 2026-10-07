#!/system/bin/sh
# VMHost · 方案 2（App / B1 路径）：在 guest 内注册 IActivityController，
# 让 system_server 的 Watchdog 判定「系统卡死」时只回调、不 SIGKILL。
#
# 与 system 版（vmhost_amctl.sh）的唯一区别：payload 放在 /vendor。
# 原因：本路径的访客镜像在设备上，system.img 有 790MB，拉下来改再推回去代价太大；
# vendor.img 只有 ~47MB，而 init 同样会解析 /vendor/etc/init/*.rc。
#
# app_process 自带 binder 线程池（AppRuntime::onStarted -> startThreadPool），
# BOOTCLASSPATH 由 init 的全局环境提供（init.environ.rc）。
# 注意放 /vendor/bin 而不是 /vendor/framework：SDK 的 vendor.img inode 用满，
# 建不了新目录，只能用已有目录（详见 inject_amctl_vendor.sh 的说明）。
export CLASSPATH=/vendor/bin/vmhost_amctl.jar
exec app_process /system/bin --nice-name=vmhost_amctl vmhost.AmController
