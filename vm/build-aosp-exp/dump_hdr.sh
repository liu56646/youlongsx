#!/system/bin/sh
# 导出三个访客镜像的分区表头（MBR + GPT），用于判定 super/逻辑分区布局
IMG=/data/user/0/com.vm.app/files/images/p11_arm64
DATA=/data/user/0/com.vm.app/files/vms/vm_1
O=/data/local/tmp
dd if="$IMG/system.img"   of=$O/hdr_system.bin   bs=512 count=40 2>/dev/null
dd if="$IMG/vendor.img"   of=$O/hdr_vendor.bin   bs=512 count=40 2>/dev/null
dd if="$DATA/userdata.img" of=$O/hdr_userdata.bin bs=512 count=40 2>/dev/null
ls -l $O/hdr_*.bin
echo "=== system.img MBR/GPT 区（前 8 行） ==="
hexdump -C -n 512 $O/hdr_system.bin
