#!/system/bin/sh
# VMHost：把 goldfish RIL 换成"空转桩"。
# 它原来每 ~20s 就 abort 一次（Abort message: 'HIDL joinRpcThreadpool without
# calling configureRpcThreadPool.'），既刷爆 logcat crash 缓冲区（把 zygote/iorapd
# 真正的崩溃信息挤掉），又把 CPU 吃掉一大块，还顺带把 sys.init.updatable_crashing
# 顶起来触发 flags_health_check 风暴。我们不需要电话功能，直接空转。
while true; do sleep 3600; done
