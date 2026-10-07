#!/usr/bin/env python3
# 在 qemu 二进制里找给定文件偏移所在/最近的【文本段】符号
import subprocess
import sys

NDK = "/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin"
B = "/mnt/k/youlongsx/vm/engine/src/main/cpp/prebuilt/qemu-aosp/arm64-v8a/qemu-system-aarch64"

out = subprocess.run([NDK + "/llvm-nm", "-C", "--defined-only", "-n", B],
                     capture_output=True, text=True).stdout
syms = []
for line in out.splitlines():
    parts = line.split(" ", 2)
    if len(parts) < 3:
        continue
    try:
        a = int(parts[0], 16)
    except ValueError:
        continue
    typ = parts[1]
    syms.append((a, typ, parts[2]))

def find(off):
    best = None
    for a, typ, n in syms:
        # 这里 nm 给的是“虚拟地址”还是“文件偏移”？二进制只有一个 PT_LOAD 起点为 0 时二者一致。
        if a <= off and (best is None or a > best[0]):
            best = (a, typ, n)
    return best

for o in sys.argv[1:]:
    off = int(o, 16)
    b = find(off)
    if b:
        print(f"0x{off:x} -> 0x{b[0]:x} [{b[1]}] {b[2]}  (+0x{off-b[0]:x})")
    else:
        print(f"0x{off:x} -> 无")
