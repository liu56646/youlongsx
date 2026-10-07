#!/usr/bin/env python3
# 最小 lpunpack：解析 super 的 lp_metadata 并导出逻辑分区
# 用法: lpunpack.py <image> [outdir] [super_off_hex]
import os, struct, sys

LP_MAGIC = 0x414C5030
GEOM_MAGIC = 0x616C4467
LINEAR = 0
ZERO = 1
TARGET_TYPE = {0: 'LINEAR', 1: 'ZERO', 2: 'ANDROID_VERITY', 3: 'ANDROID_FEC'}


def find_gpt_part(image, want):
    """从镜像 GPT 里找某分区名的 (起始字节, 扇区数)"""
    with open(image, 'rb') as f:
        f.seek(512)
        hdr = f.read(92)
        if hdr[:8] != b'EFI PART':
            return None
        part_lba = struct.unpack_from('<Q', hdr, 72)[0]
        num = struct.unpack_from('<I', hdr, 80)[0]
        esz = struct.unpack_from('<I', hdr, 84)[0]
        f.seek(part_lba * 512)
        data = f.read(num * esz)
    for i in range(num):
        e = data[i * esz:(i + 1) * esz]
        if e[:16] == b'\x00' * 16:
            continue
        name = e[56:128].decode('utf-16-le', 'replace').split('\x00')[0]
        if name == want:
            first = struct.unpack_from('<Q', e, 32)[0]
            last = struct.unpack_from('<Q', e, 40)[0]
            return first * 512, (last - first + 1)
    return None


def parse_header(data, off):
    magic = struct.unpack_from('<I', data, off)[0]
    assert magic == LP_MAGIC, "lp_metadata magic 不匹配: %08x" % magic
    major, minor = struct.unpack_from('<HH', data, off + 4)
    header_size = struct.unpack_from('<I', data, off + 8)[0]
    tables_size = struct.unpack_from('<I', data, off + 44)[0]
    # 注意：本版 header 用 32 字节 SHA 校验和，描述符从 0x50 开始
    def table(idx):
        o, n, s = struct.unpack_from('<III', data, off + 0x50 + idx * 12)
        return o, n, s
    return major, minor, header_size, tables_size, table


def main():
    image = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else None
    super_off = int(sys.argv[3], 16) if len(sys.argv) > 3 else None
    if super_off is None:
        g = find_gpt_part(image, 'super')
        if not g:
            print("找不到 super 分区"); return 1
        super_off = g[0]
    print("super 起始偏移 = 0x%x" % super_off)

    with open(image, 'rb') as f:
        f.seek(super_off)
        head = f.read(0x3000 + 0x1000)     # geometry + header
    hdr_off = head.find(struct.pack('<I', LP_MAGIC))
    assert hdr_off > 0, "super 内找不到 lp_metadata 头"
    print("lp_metadata 头在 super 内偏移 = 0x%x" % hdr_off)

    major, minor, header_size, tables_size, table = parse_header(head, hdr_off)
    print("version=%d.%d header_size=%d tables_size=%d" % (major, minor, header_size, tables_size))

    tbase = hdr_off + header_size
    po, pn, ps = table(0)
    eo, en, es = table(1)
    go, gn, gs = table(2)
    bo, bn, bs = table(3)
    print("partition=%d/%d  extent=%d/%d  group=%d  blockdev=%d" % (pn, ps, en, es, gn, bn))

    parts = []
    for i in range(pn):
        o = tbase + po + i * ps
        name = head[o:o + 36].split(b'\x00')[0].decode('ascii', 'replace')
        attrs, first_ext, num_ext, grp = struct.unpack_from('<IIII', head, o + 36)
        parts.append((name, first_ext, num_ext, grp))
    exts = []
    for i in range(en):
        o = tbase + eo + i * es
        num_sectors, ttype, tdata, tsrc = struct.unpack_from('<QIQI', head, o)
        exts.append((num_sectors, ttype, tdata, tsrc))

    if outdir:
        os.makedirs(outdir, exist_ok=True)
    total = 0
    for name, first_ext, num_ext, grp in parts:
        size = sum(exts[first_ext + k][0] for k in range(num_ext)) * 512
        total += size
        print("  分区 %-14s extents=%d 大小=%.1f MB" %
              (name, num_ext, size / 1048576.0))
        for k in range(num_ext):
            ns, tt, td, ts = exts[first_ext + k]
            print("      extent: %-6s sectors=%d data_off=0x%x" % (TARGET_TYPE.get(tt, tt), ns, td))
        if outdir:
            path = os.path.join(outdir, name + ".img")
            with open(image, 'rb') as f, open(path, 'wb') as out:
                for k in range(num_ext):
                    ns, tt, td, ts = exts[first_ext + k]
                    assert tt == LINEAR, "非 LINEAR extent，暂不支持"
                    f.seek(super_off + td * 512)
                    left = ns * 512
                    while left > 0:
                        chunk = f.read(min(left, 1 << 24))
                        if not chunk:
                            break
                        out.write(chunk)
                        left -= len(chunk)
            print("      -> %s" % path)
    print("逻辑分区合计 %.1f MB" % (total / 1048576.0))
    return 0


if __name__ == '__main__':
    sys.exit(main())
