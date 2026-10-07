#!/usr/bin/env python3
# 从 crash 记录里找出故障 PC 落在哪个映射
import re, sys

p = "/mnt/k/youlongsx/vm/build-aosp-exp/qemu_crash.txt"
txt = open(p, encoding="utf-8", errors="replace").read()
head = txt.split("=== MAPS ===")[0]
print(head.strip()[:600])
print("-" * 60)

m = re.search(r"PC=0x([0-9a-f]+)", txt)
if not m:
    print("no PC")
    sys.exit(1)
pc = int(m.group(1), 16)
print("PC = 0x%x" % pc)

found = False
for line in txt.splitlines():
    mm = re.match(r"^([0-9a-f]+)-([0-9a-f]+)\s+(\S{4})\s+(\S+)\s+\S+\s+\S+\s*(.*)$", line)
    if not mm:
        continue
    lo, hi = int(mm.group(1), 16), int(mm.group(2), 16)
    if lo <= pc < hi:
        print("IN MAP:", line)
        found = True
        break
if not found:
    print("PC 不在任何映射内 —— 说明是野指针/跳飞")
    # 找最近的映射
    near = []
    for line in txt.splitlines():
        mm = re.match(r"^([0-9a-f]+)-([0-9a-f]+)\s+(\S{4})\s+", line)
        if mm:
            near.append((int(mm.group(1), 16), int(mm.group(2), 16), line))
    near.sort()
    for lo, hi, line in near:
        if lo > pc:
            print("下一个映射:", line)
            break
        prev = line
    print("上一个映射:", prev)

# 打印所有可执行且体积大的匿名/代码缓冲候选
print("-" * 60)
for line in txt.splitlines():
    mm = re.match(r"^([0-9a-f]+)-([0-9a-f]+)\s+(\S{4})\s+", line)
    if not mm:
        continue
    lo, hi = int(mm.group(1), 16), int(mm.group(2), 16)
    perm = mm.group(3)
    if "x" in perm and (hi - lo) >= 0x100000:
        print("EXEC_REGION %12d  %s" % (hi - lo, line))
