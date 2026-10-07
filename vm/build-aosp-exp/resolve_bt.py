#!/usr/bin/env python3
# 把 hwc_crash.log 里的回溯 PC 按同文件里的 maps 解析成 模块 + 文件偏移
import re
import sys
import os

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hwc_crash.log")

pcs = []
maps = []
blk = None
with open(LOG, "r", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("--- backtrace"):
            blk = "bt"; continue
        if line.startswith("--- end backtrace"):
            blk = None; continue
        if line.startswith("--- maps"):
            blk = "maps"; continue
        if line.startswith("--- end maps"):
            blk = None; continue
        if blk == "bt":
            m = re.match(r"\s+0x([0-9a-f]+)\s*$", line)
            if m:
                pcs.append(int(m.group(1), 16))
        elif blk == "maps":
            m = re.match(r"([0-9a-f]+)-([0-9a-f]+)\s+(\S+)\s+([0-9a-f]+)\s+\S+\s+\S+\s*(.*)$", line)
            if m:
                maps.append((int(m.group(1),16), int(m.group(2),16), int(m.group(4),16), m.group(5).strip()))

def resolve(pc):
    for s, e, off, path in maps:
        if s <= pc < e:
            return path, pc - s + off
    return None, None

print(f"pcs={len(pcs)} maps={len(maps)}")
for pc in pcs:
    path, foff = resolve(pc)
    if path:
        print(f"0x{pc:x}  {path}  +0x{foff:x}")
    else:
        print(f"0x{pc:x}  <no map>")
