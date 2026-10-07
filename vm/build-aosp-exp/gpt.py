#!/usr/bin/env python3
# 打印镜像内 GPT 的分区名/起止扇区
import struct, sys

def dump(path):
    with open(path, 'rb') as f:
        f.seek(512)
        hdr = f.read(512)
    if hdr[:8] != b'EFI PART':
        print(f"{path}: 无 GPT（前 512 字节非 EFI PART）")
        return
    part_lba = struct.unpack_from('<Q', hdr, 72)[0]
    num = struct.unpack_from('<I', hdr, 80)[0]
    esz = struct.unpack_from('<I', hdr, 84)[0]
    print(f"{path}: GPT 分区数={num} 表位置 LBA={part_lba} 项大小={esz}")
    with open(path, 'rb') as f:
        f.seek(part_lba * 512)
        data = f.read(num * esz)
    for i in range(num):
        e = data[i * esz:(i + 1) * esz]
        if len(e) < 128:
            break
        type_guid = e[0:16]
        if type_guid == b'\x00' * 16:
            continue
        first = struct.unpack_from('<Q', e, 32)[0]
        last = struct.unpack_from('<Q', e, 40)[0]
        name = e[56:128].decode('utf-16-le', 'replace').split('\x00')[0]
        print(f"  #{i+1}: name={name!r} first_lba={first} last_lba={last} sectors={last-first+1}")

for p in sys.argv[1:]:
    dump(p)
