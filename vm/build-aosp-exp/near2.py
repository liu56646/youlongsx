#!/usr/bin/env python3
# 把“core 里的文件偏移”换算成 ELF 的 vaddr，再用 llvm-symbolizer（qemu 有 49944 个符号）
import struct
import subprocess
import sys

NDK = "/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin"
B = "/mnt/k/youlongsx/vm/engine/src/main/cpp/prebuilt/qemu-aosp/arm64-v8a/qemu-system-aarch64"

bh = open(B, "rb").read(1024 * 1024)
e_phoff, = struct.unpack_from("<Q", bh, 0x20)
e_phentsize, = struct.unpack_from("<H", bh, 0x36)
e_phnum, = struct.unpack_from("<H", bh, 0x38)
loads = []
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    t, fl, poff, vaddr, paddr, fsz, msz = struct.unpack_from("<IIQQQQQ", bh, off)
    if t == 1:
        loads.append((poff, vaddr, fsz))

def fo2va(fo):
    for poff, vaddr, fsz in loads:
        if poff <= fo < poff + fsz:
            return vaddr + (fo - poff)
    return None

for a in sys.argv[1:]:
    fo = int(a, 16)
    va = fo2va(fo)
    if va is None:
        print(f"file+0x{fo:x} -> 不在任何 PT_LOAD")
        continue
    r = subprocess.run([NDK + "/llvm-symbolizer", "--obj=" + B, f"0x{va:x}"],
                       capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    print(f"file+0x{fo:x} -> va 0x{va:x} : " + (" | ".join(lines[:2]) if lines else "??"))
