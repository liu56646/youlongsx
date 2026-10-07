#!/usr/bin/env bash
cd /mnt/k/youlongsx/vm/build-aosp-exp
L=g38.log
echo "=== 日志里与 console 相关的行（前 30）==="
grep -anE 'console' "$L" | grep -avE 'console -b|console=ttyAMA0|ConsoleService|consola' | head -30
echo
echo "=== 出现 '(deleted)' 的 console 路径最早几次 ==="
grep -anE '2F6465762F636F6E736F6C65' "$L" | head -5
echo
echo "=== ramdisk 里有没有静态 /dev/console ==="
rm -rf /tmp/rdp3; mkdir -p /tmp/rdp3
python3 extract_cpio.py ramdisk_probe.img /tmp/rdp3 >/dev/null 2>&1 || true
ls -la /tmp/rdp3/dev/ 2>/dev/null | head -20
echo
echo "=== ramdisk 的 init 脚本/文件列表根部 ==="
ls -la /tmp/rdp3 | head -20
