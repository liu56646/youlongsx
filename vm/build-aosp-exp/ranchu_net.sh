#!/vendor/bin/sh

# Check if VirtIO Wi-Fi is enabled. If so, run the DHCP client

wifi_virtio=`getprop ro.kernel.qemu.virtiowifi`
case "$wifi_virtio" in
    1) setprop ctl.start dhcpclient_wifi
       ;;
esac

# Check if WiFi with mac80211_hwsim is enabled. If so, run the WiFi init script. If not we just
# have to run the DHCP client in the default namespace and that will set up
# all the networking.
#
# VMHost: 本 guest 未接任何网卡（QEMU 没有 virtio-net），eth0 不存在，于是
# dhcpclient_def 立刻 exit 1；init 会每 ~7s 自动重启它，并把
# sys.init.updatable_crashing 顶起来，导致 flags_health_check UPDATABLE_CRASHING
# 被反复阻塞式 exec（实测 9 小时 5258 次）。所以先确认 eth0 存在再启动。
wifi_hwsim=`getprop ro.kernel.qemu.wifi`
case "$wifi_hwsim" in
    1) /vendor/bin/init.wifi.sh
       ;;
    *) if [ -e /sys/class/net/eth0 ]; then
           setprop ctl.start dhcpclient_def
       fi
       ;;
esac

# set up the second interface (for inter-emulator connections)
# if required
my_ip=`getprop net.shared_net_ip`
case "$my_ip" in
    "")
    ;;
    *) ifconfig eth1 "$my_ip" netmask 255.255.255.0 up
    ;;
esac
