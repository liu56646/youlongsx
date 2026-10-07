#!/usr/bin/env python3
# hexdump 指定偏移，辅助确认 lp_metadata 头字段布局
import sys
path = sys.argv[1]
off = int(sys.argv[2], 16)
n = int(sys.argv[3]) if len(sys.argv) > 3 else 176
data = open(path, 'rb').read()[off:off + n]
for i in range(0, len(data), 16):
    chunk = data[i:i + 16]
    hexs = ' '.join('%02x' % b for b in chunk)
    txt = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
    print("%08x  %-47s  %s" % (off + i, hexs, txt))
