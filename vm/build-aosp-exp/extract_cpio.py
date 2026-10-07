#!/usr/bin/env python3
# 解析「多段拼接」的 newc cpio（模拟器 ramdisk 常见做法）
import os, sys, gzip

src = sys.argv[1]
dst = sys.argv[2]
raw = open(src, 'rb').read()
if raw[:2] == b'\x1f\x8b':
    data = gzip.decompress(raw)
else:
    data = raw
print("解压后大小 = %d (0x%x)" % (len(data), len(data)))

os.makedirs(dst, exist_ok=True)
pos = 0
entry = 0
while pos < len(data):
    # 对齐到下一个 "070701"
    hdr = data.find(b'070701', pos)
    if hdr < 0:
        break
    if hdr != pos:
        pos = hdr
    h = data[pos:pos + 110]
    if len(h) < 110:
        break
    try:
        filesize = int(h[54:62], 16)
        namesize = int(h[94:102], 16)
        mode = int(h[14:22], 16)
    except ValueError:
        pos += 6
        continue
    name = data[pos + 110:pos + 110 + namesize - 1].decode('utf-8', 'replace')
    datapos = pos + 110 + namesize
    datapos = (datapos + 3) & ~3
    if name == 'TRAILER!!!':
        pos = datapos
        continue
    full = os.path.join(dst, name.lstrip('/'))
    if mode & 0o170000 == 0o040000:      # dir
        os.makedirs(full, exist_ok=True)
    elif mode & 0o170000 == 0o120000:    # symlink
        link = data[datapos:datapos + filesize].decode('utf-8', 'replace')
        if os.path.lexists(full):
            os.remove(full)
        os.symlink(link, full)
    else:
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, 'wb') as f:
            f.write(data[datapos:datapos + filesize])
        os.chmod(full, mode & 0o7777)
    entry += 1
    pos = datapos + ((filesize + 3) & ~3)

print("解出条目 = %d" % entry)
