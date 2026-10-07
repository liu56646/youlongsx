#!/usr/bin/env python3
import struct, sys
data = open(sys.argv[1], 'rb').read()
m = struct.pack('<I', 0x414C5030)
i = 0
found = []
while True:
    i = data.find(m, i)
    if i < 0:
        break
    found.append(i)
    i += 1
print("lp_metadata magic 偏移:", [hex(x) for x in found] or "无")
# 找分区名候选
for kw in [b'system_ext', b'product', b'vendor', b'system', b'vbmeta']:
    j = data.find(kw)
    print(kw.decode(), "首次出现:", hex(j) if j >= 0 else "无")
