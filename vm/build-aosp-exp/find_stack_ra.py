#!/usr/bin/env python3
# 在 dump 出来的栈里找落在 QEMU 代码段的返回地址，并输出可用于符号化的偏移
import re, subprocess, os

P = "/mnt/k/youlongsx/vm/build-aosp-exp/qemu_crash.txt"
OBJ = "/root/vmbuild/qemu-aosp-build-arm64-v8a/aarch64-softmmu/qemu-system-aarch64"
SYM = "/root/vmbuild/android-ndk-r28/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-symbolizer"

txt = open(P, encoding="utf-8", errors="replace").read()
print(txt.split("=== MAPS ===")[0].strip()[:400])
print("=" * 70)

m = re.search(r"exe_base=0x([0-9a-f]+)", txt)
base = int(m.group(1), 16)

# 找 exe 的 r-xp 映射
text_lo = text_hi = 0
for line in txt.splitlines():
    if "qemu-system-aarch64" in line and "r-xp" in line:
        mm = re.match(r"^([0-9a-f]+)-([0-9a-f]+)", line)
        text_lo, text_hi = int(mm.group(1), 16), int(mm.group(2), 16)
        print("TEXT:", line)
        break
print("base=0x%x text=0x%x-0x%x" % (base, text_lo, text_hi))

# 取 STACK 段
sm = re.search(r"=== STACK.*?===\n(.*?)=== END STACK ===", txt, re.S)
if not sm:
    print("no stack dump")
    raise SystemExit(1)

cands = []
for ln in sm.group(1).splitlines():
    mm = re.match(r"^(\d+)\s+0x([0-9a-f]+)$", ln.strip())
    if not mm:
        continue
    idx, val = int(mm.group(1)), int(mm.group(2), 16)
    if text_lo <= val < text_hi:
        cands.append((idx, val, val - base))

print("栈中指向代码段的候选 (%d 个):" % len(cands))
offs = []
for idx, val, off in cands:
    print("  [%3d] 0x%x  off=0x%x" % (idx, val, off))
    offs.append(hex(off))

if offs:
    out = subprocess.run([SYM, "--obj=" + OBJ, "--functions=linkage", "--inlines"] + offs,
                         capture_output=True, text=True)
    print("=" * 70)
    print(out.stdout)
