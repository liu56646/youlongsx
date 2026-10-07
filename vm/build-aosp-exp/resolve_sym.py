#!/usr/bin/env python3
# 解析 hwc_crash.log 的回溯 PC：先按 maps 归到模块 + vaddr，再尝试符号化
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "hwc_crash.log")

NDK = "/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin"
SYMBOLIZER = os.path.join(NDK, "llvm-symbolizer")

# maps 里的模块 -> 本地已抽取的文件
LOCAL = {
    "/vendor/bin/hw/android.hardware.graphics.composer@2.3-service":
        "/tmp/hwclibs/composer-service",
    "/vendor/lib64/hw/hwcomposer.ranchu.so":
        "/tmp/hwclibs/hwcomposer.ranchu.so",
    "/vendor/lib64/hw/android.hardware.graphics.mapper@3.0-impl-ranchu.so":
        "/tmp/hwclibs/mapper30-impl-ranchu.so",
}

pcs, maps = [], []
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
                maps.append((int(m.group(1), 16), int(m.group(2), 16),
                             int(m.group(4), 16), m.group(5).strip()))

# 每个模块的 load bias = offset==0 的那个映射的起始地址
bias = {}
for s, e, off, path in maps:
    if path and off == 0:
        bias.setdefault(path, s)

def resolve(pc):
    for s, e, off, path in maps:
        if s <= pc < e:
            return path, pc - bias.get(path, s)
    return None, None

# 只保留第一段栈（后面是重复的多次崩溃）
first = []
seen = set()
for pc in pcs:
    path, va = resolve(pc)
    if path is None:
        first.append((pc, None, None)); continue
    key = (path, va)
    if key in seen and len(first) > 3:
        # 粗略去重：遇到重复整栈就停
        pass
    first.append((pc, path, va))

# 打印（仅第一段，遇到第二次出现 libc+0x4de4c 就截断）
out = []
for i, (pc, path, va) in enumerate(first):
    if i > 0 and path and path.endswith("libc.so") and va == 0x4DE4C:
        break
    out.append((pc, path, va))

print(f"pcs={len(pcs)}  解析第一段={len(out)} 条")
print()
for pc, path, va in out:
    if path is None:
        print(f"0x{pc:012x}  <no map>")
        continue
    name = os.path.basename(path)
    sym = ""
    local = LOCAL.get(path)
    if local and os.path.exists(local):
        try:
            r = subprocess.run([SYMBOLIZER, "--obj=" + local, f"0x{va:x}"],
                               capture_output=True, text=True, timeout=20)
            lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
            if lines:
                sym = "  | " + " | ".join(lines[:2])
        except Exception as ex:
            sym = f"  | <sym err {ex}>"
    print(f"0x{pc:012x}  {name} +0x{va:x}{sym}")
