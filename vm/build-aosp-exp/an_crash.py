#!/usr/bin/env python3
# 解析 guest 侧 crash.log（crashlite 产出）：把每个崩溃块的回溯帧按 maps 归到 模块+偏移
import os
import re
import subprocess
import sys

NDK = "/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin"
LOG = "/mnt/k/youlongsx/vm/build-aosp-exp/crash_extract.log"

blocks = []
cur = None
with open(LOG, "r", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("########## CRASH"):
            cur = {"hdr": [], "bt": [], "maps": []}
            blocks.append(cur)
            continue
        if line.startswith("########## END"):
            cur = None
            continue
        if cur is None:
            continue
        m = re.match(r"  0x([0-9a-f]+)\s*$", line)
        if m and not cur["maps"]:
            cur["bt"].append(int(m.group(1), 16))
            continue
        m = re.match(r"([0-9a-f]+)-([0-9a-f]+)\s+\S+\s+([0-9a-f]+)\s+\S+\s+\S+\s*(.*)$", line)
        if m:
            cur["maps"].append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16), m.group(4).strip()))
            continue
        if line.startswith(("comm=", "pc=")):
            cur["hdr"].append(line)

def resolve(maps, addr):
    for s, e, fo, path in maps:
        if s <= addr < e:
            return path, addr - s + fo
    return None, None

for b in blocks:
    print(" | ".join(b["hdr"]))
    for a in b["bt"][:22]:
        p, off = resolve(b["maps"], a)
        if p:
            print(f"   0x{a:x} -> {p.split('/')[-1]} +0x{off:x}")
        else:
            print(f"   0x{a:x} -> <no map>")
    print()
