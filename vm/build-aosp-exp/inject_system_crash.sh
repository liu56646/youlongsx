#!/usr/bin/env bash
# 把「轻量崩溃捕获」注入 system_cur.img -> system_bt.img：
#   - /system/lib64/libcrashlite.so（信号处理器 + 帧指针回溯 + maps -> /metadata/crash.log）
#   - iorapd / zygote 走 wrapper（LD_PRELOAD）
#   - logcatd 降噪（-b crash,main,system）
#   - hwcbt：状态记录 + 预建 /metadata/crash.log(0666)
set -e
cd /mnt/k/youlongsx/vm/build-aosp-exp

SRC=system_cur.img
DST=system_bt.img

sed -i 's/\r$//' hwcbt.sh hwcbt.rc logcatd_debug.rc \
    vmhost_iorapd_wrap.sh vmhost_zygote_wrap.sh iorapd_crash.rc zygote64_crash.rc \
    vmhost_input.rc vmhost_amctl.sh vmhost_amctl.rc

cp -f "$SRC" "$DST"
e2fsck -fy "$DST" >/dev/null 2>&1 || true

put() { # put <本地文件> <镜像内路径> <八进制mode>
    debugfs -w -R "write $1 $2" "$DST" >/dev/null 2>&1
    debugfs -w -R "sif $2 mode $3" "$DST" >/dev/null 2>&1
}
putf() { # putf <本地文件> <镜像内路径> <八进制mode>：先删再写
    debugfs -w -R "rm $2" "$DST" >/dev/null 2>&1 || true
    put "$1" "$2" "$3"
}

put  libcrashlite.so          /system/lib64/libcrashlite.so                     0100644
put  vmhost_iorapd_wrap.sh    /system/bin/vmhost_iorapd_wrap.sh                 0100755
put  vmhost_zygote_wrap.sh    /system/bin/vmhost_zygote_wrap.sh                 0100755
putf iorapd_crash.rc          /etc/init/iorapd.rc                               0100644
putf zygote64_crash.rc        /etc/init/hw/init.zygote64.rc                     0100644
putf logcatd_debug.rc         /etc/init/logcatd.rc                              0100644
put  hwcbt.sh                 /system/bin/hwcbt.sh                              0100755
putf hwcbt.rc                 /etc/init/hwcbt.rc                                0100644
putf vmhost_input.rc          /etc/init/vmhost_input.rc                         0100644
# 方案 2：IActivityController 控制器（让 Watchdog 只回调不杀）
put  vmhost_amctl.jar         /system/framework/vmhost_amctl.jar                0100644
put  vmhost_amctl.sh          /system/bin/vmhost_amctl.sh                       0100755
putf vmhost_amctl.rc          /etc/init/vmhost_amctl.rc                         0100644

e2fsck -fy "$DST" >/dev/null 2>&1 || true

echo "--- iorapd.rc ---";    debugfs -R "cat /etc/init/iorapd.rc" "$DST" 2>/dev/null | grep -E '^service|seclabel'
echo "--- zygote64.rc ---";  debugfs -R "cat /etc/init/hw/init.zygote64.rc" "$DST" 2>/dev/null | grep -E '^service|seclabel'
echo "--- logcatd.rc ---";   debugfs -R "cat /etc/init/logcatd.rc" "$DST" 2>/dev/null | grep logcat
echo "--- vmhost_input.rc ---"; debugfs -R "cat /etc/init/vmhost_input.rc" "$DST" 2>/dev/null | grep -E 'mkdir|^on '
echo "--- vmhost_amctl.rc ---"; debugfs -R "cat /etc/init/vmhost_amctl.rc" "$DST" 2>/dev/null | grep -E '^service|^on |^    (class|user|start)'
echo "--- vmhost_amctl.sh ---"; debugfs -R "cat /system/bin/vmhost_amctl.sh" "$DST" 2>/dev/null | tail -2
echo "--- vmhost_amctl.jar ---"; debugfs -R "stat /system/framework/vmhost_amctl.jar" "$DST" 2>/dev/null | head -5
echo "--- modes ---"
for p in /system/lib64/libcrashlite.so /system/bin/vmhost_iorapd_wrap.sh /system/bin/vmhost_zygote_wrap.sh \
         /etc/init/iorapd.rc /etc/init/hw/init.zygote64.rc /etc/init/logcatd.rc /etc/init/hwcbt.rc \
         /etc/init/vmhost_input.rc /etc/init/vmhost_amctl.rc /system/bin/vmhost_amctl.sh \
         /system/framework/vmhost_amctl.jar; do
    printf "%-45s " "$p"
    debugfs -R "stat $p" "$DST" 2>/dev/null | grep -m1 'Mode:'
done
ls -la "$DST"
