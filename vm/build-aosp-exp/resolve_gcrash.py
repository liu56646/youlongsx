#!/usr/bin/env python
# 解析 gcrash.log（crashlite 多记录），把每条 crash 的回溯 PC 按同记录的 maps 解析成 模块+偏移
import re
import sys
import os

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gcrash.log")

recs = []
cur = None
blk = None
with open(LOG, "r", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("########## CRASH"):
            cur = {"hdr": None, "pcs": [], "maps": []}
            recs.append(cur)
            blk = None
            continue
        if cur is None:
            continue
        if line.startswith("comm=") and cur["hdr"] is None:
            cur["hdr"] = line
            continue
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
                cur["pcs"].append(int(m.group(1), 16))
        elif blk == "maps":
            m = re.match(r"([0-9a-f]+)-([0-9a-f]+)\s+(\S+)\s+([0-9a-f]+)\s+\S+\s+\S+\s*(.*)$", line)
            if m:
                cur["maps"].append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(4), 16), m.group(5).strip()))

def resolve(pc, maps):
    for s, e, off, path in maps:
        if s <= pc < e:
            return path, pc - s + off
    return None, None

pat = sys.argv[1] if len(sys.argv) > 1 else None
for r in recs:
    h = r["hdr"] or "?"
    if pat and pat not in h:
        continue
    print("=" * 70)
    print(h)
    for pc in r["pcs"]:
        path, foff = resolve(pc, r["maps"])
        if path:
            print(f"  0x{pc:x}  {path}  +0x{foff:x}")
        else:
            print(f"  0x{pc:x}  <no map>")
