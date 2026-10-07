#!/usr/bin/env python3
# 在镜像里自动找到 lp_metadata 头（magic 0x414c5030）并列出逻辑分区
import struct, sys

path = sys.argv[1]
data = open(path, 'rb').read()
magic = struct.pack('<I', 0x414C5030)
off = data.find(magic)
if off < 0:
    print("未找到 lp_metadata 头")
    sys.exit(1)
print("header 偏移 = 0x%x" % off)

hdr = data[off:off + 256]
major, minor = struct.unpack_from('<HH', hdr, 4)
header_size = struct.unpack_from('<I', hdr, 8)[0]
print("version=%d.%d header_size=%d" % (major, minor, header_size))

def table(idx):
    # LpMetadataHeader: magic(0) ver(4) hdrsize(8) hdrsum(12) tblsize(16) tblsum(20)
    # 之后是 4 个 LpMetadataTableDescriptor，各 12 字节，从偏移 24 开始
    o = struct.unpack_from('<I', hdr, 24 + idx * 12)[0]
    n = struct.unpack_from('<I', hdr, 28 + idx * 12)[0]
    sz = struct.unpack_from('<I', hdr, 32 + idx * 12)[0]
    return o, n, sz

tables_off = off + header_size
poff, pnum, psz = table(0)
print("分区数=%d 项大小=%d" % (pnum, psz))
for i in range(pnum):
    e = data[tables_off + poff + i * psz: tables_off + poff + (i + 1) * psz]
    name = e[0:36].split(b'\x00')[0].decode('ascii', 'replace')
    _, _, num_extents, group = struct.unpack_from('<IIII', e, 36)
    print("  [%d] name=%s extents=%d group=%d" % (i, name if name else '<空>', num_extents, group))

goff, gnum, gsz = table(2)
print("group 数=%d" % gnum)
for i in range(gnum):
    e = data[tables_off + goff + i * gsz: tables_off + goff + (i + 1) * gsz]
    name = e[0:36].split(b'\x00')[0].decode('ascii', 'replace')
    print("  group[%d]=%s" % (i, name))
