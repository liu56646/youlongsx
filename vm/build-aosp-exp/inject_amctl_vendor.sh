#!/usr/bin/env bash
# 把 amctl（IActivityController 控制器）注入 vendor.img —— App / B1 路径用。
#
# 为什么注进 /vendor 而不是 /system：
#   本路径的访客镜像在设备上（files/images/p11_arm64/），system.img 有 790MB，
#   拉下来改再推回去代价太大；vendor.img 只有 ~47MB，而 init 同样会解析
#   /vendor/etc/init/*.rc，效果一致。
#
# 为什么先删两个文件：
#   SDK 的 vendor.img 是"打包到 inode 用满"的，既建不了新目录也写不了新文件
#   （resize2fs 扩容只加块、不加 inode）。所以这里删掉三个运行期用不到的文件
#   腾出 inode：
#     /etc/NOTICE.xml.gz     —— 开源许可文本，运行期没人读
#     /etc/fs_config_dirs    —— 0 字节占位；这两个是**构建期**工具用的文件清单，
#     /etc/fs_config_files      运行期 init 读的是 /etc/selinux/*，不是它们
#
# 前置：guest 以 androidboot.selinux=permissive + veritymode=disabled 启动
#       （见 vm/engine/src/main/cpp/src/vm_qemu.c 的 -append），改镜像安全。
#
# 用法：
#   adb exec-out run-as com.vm.app cat files/images/p11_arm64/vendor.img > vendor_cur.img
#   wsl -d Ubuntu bash -lc 'cd /mnt/k/youlongsx/vm/build-aosp-exp && bash inject_amctl_vendor.sh'
#   # 产物 vendor_amctl.img → 推回设备替换 files/images/p11_arm64/vendor.img
#   adb push vendor_amctl.img /data/local/tmp/
#   adb shell "am force-stop com.vm.app; run-as com.vm.app cp /data/local/tmp/vendor_amctl.img files/images/p11_arm64/vendor.img"
#
# 前置条件：先在 Windows 侧跑 build_amctl.ps1 生成 vmhost_amctl.jar。
set -e
cd "$(dirname "$0")"

SRC="${SRC:-vendor_cur.img}"
DST="${DST:-vendor_amctl.img}"

sed -i 's/\r$//' vmhost_amctl_vendor.sh vmhost_amctl_vendor.rc

cp -f "$SRC" "$DST"
e2fsck -fy "$DST" >/dev/null 2>&1 || true

# 腾 inode：三个运行期用不到的文件
for victim in /etc/NOTICE.xml.gz /etc/fs_config_dirs /etc/fs_config_files; do
    debugfs -w -R "rm $victim" "$DST" >/dev/null 2>&1 || true
done

put() { # put <本地文件> <镜像内路径> <八进制mode>
    debugfs -w -R "write $1 $2" "$DST" >/dev/null 2>&1
    debugfs -w -R "sif $2 mode $3" "$DST" >/dev/null 2>&1
}

put vmhost_amctl.jar       /bin/vmhost_amctl.jar        0100644
put vmhost_amctl_vendor.sh /bin/vmhost_amctl.sh         0100755
put vmhost_amctl_vendor.rc /etc/init/vmhost_amctl.rc    0100644

e2fsck -fy "$DST" >/dev/null 2>&1 || true

echo "--- 校验 ---"
for p in /bin/vmhost_amctl.jar /bin/vmhost_amctl.sh /etc/init/vmhost_amctl.rc; do
    printf "%-34s " "$p"
    debugfs -R "stat $p" "$DST" 2>/dev/null | grep -m1 'Mode:' || echo "(缺失!)"
done
echo "--- rc 关键行 ---"
debugfs -R "cat /etc/init/vmhost_amctl.rc" "$DST" 2>/dev/null | grep -E '^service|^on |^    (class|user|start)'
echo "--- sh 尾 2 行 ---"
debugfs -R "cat /bin/vmhost_amctl.sh" "$DST" 2>/dev/null | tail -2
ls -l "$DST"
