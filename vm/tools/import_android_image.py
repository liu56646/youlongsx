#!/usr/bin/env python3
"""Inspect/normalize third-party Android images; extraction is not hardware emulation.

Standard library only. Optional installed tools: payload-dumper-go, brotli,
qemu-img; EROFS partitions need Linux as root with mount and e2fsprogs.
Never executes programs or flash scripts from a ROM archive.
"""
import argparse
import gzip
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile

LIMIT = 48 * 1024**3
DISKS = {f"{s}.img" for s in ("system", "vendor", "product", "system_ext", "userdata", "metadata", "encryptionkey")}
BUNDLE = DISKS | {"kernel", "ramdisk.img", "vmhost_guest_p9", "vmhost_guest_p71", "vmhost-image.properties"}
SPECIAL = {"payload.bin", "super.img", "boot.img", "vendor_boot.img", "init_boot.img"}


def check(condition, message):
    if not condition:
        raise ValueError(message)


def copy_stream(src, dst, budget=LIMIT):
    size = 0
    while data := src.read(1024 * 1024):
        size += len(data)
        check(size <= budget, "Image exceeds the 48 GiB conversion limit")
        dst.write(data)
    return size


def normalized(name, slot):
    parts = name.replace("\\", "/").split("/")
    check(not name.startswith("/") and ":" not in name and ".." not in parts, f"Unsafe archive path: {name}")
    name = parts[-1]
    # Motorola splits super into sparse chunks; Pixel factory zips nest the images.
    if re.fullmatch(r"super\.img_sparsechunk\.\d{1,4}", name) or re.fullmatch(r"image-[\w.-]+\.zip", name):
        return name
    if name in ("kernel-ranchu", "kernel-ranchu-64"):
        return "kernel"
    if name.endswith(("_a.img", "_b.img")):
        if not name.endswith(f"_{slot}.img"):
            return None
        name = name[:-6] + ".img"
    if name in BUNDLE | SPECIAL or name.endswith((".new.dat", ".new.dat.br", ".transfer.list")):
        return name
    return None


def collect(source, dest, slot="a"):
    """Read only selected regular files. No archive paths, symlinks or scripts escape dest."""
    source, dest = Path(source), Path(dest)
    dest.mkdir(exist_ok=True)
    total = 0
    chunks = {}

    def target_for(name):
        target = dest / name
        check(not target.exists(), f"Multiple copies of {name}; select one slot/architecture first")
        return target

    def add(name, opener, nested=False):
        nonlocal total
        name = normalized(name, slot)
        if name is None:
            return
        if name.startswith("super.img_sparsechunk."):
            index = int(name.rsplit(".", 1)[1])
            check(index not in chunks, f"Multiple copies of {name}; select one slot/architecture first")
            chunks[index] = opener
        elif name == "super.img":
            total += extract_super([opener], target_for, slot, LIMIT - total)
        elif name.endswith(".zip"):
            check(not nested, "Image archives nested more than one level are not accepted")
            with opener() as stream, zipfile.ZipFile(stream) as inner:
                add_zip(inner, nested=True)
        else:
            with opener() as stream, target_for(name).open("xb") as out:
                total += copy_stream(stream, out, LIMIT - total)

    def finish_chunks():
        # Chunks share super's raw offset space and must be read in index order,
        # while their container is still open.
        nonlocal total
        if chunks:
            check(sorted(chunks) == list(range(len(chunks))), "super.img sparse chunks are incomplete")
            total += extract_super([chunks[i] for i in sorted(chunks)], target_for, slot, LIMIT - total)
            chunks.clear()

    def add_zip(archive, nested=False):
        for info in archive.infolist():
            check((info.external_attr >> 16) & 0o170000 != 0o120000, "ZIP symlinks are not accepted")
            if not info.is_dir():
                # Validate every path, even entries we do not extract.
                if normalized(info.filename, slot):
                    add(info.filename, lambda info=info: archive.open(info), nested)
        finish_chunks()

    if source.is_dir():
        for path in source.rglob("*"):
            check(not path.is_symlink(), f"Symlinks are not accepted: {path.name}")
            if path.is_file():
                add(path.relative_to(source).as_posix(), lambda path=path: path.open("rb"))
        finish_chunks()
    elif zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as archive:
            add_zip(archive)
    elif source.name.endswith((".img.xz", ".img.gz")):
        opener = lzma.open if source.suffix == ".xz" else gzip.open
        add(source.stem if source.stem in DISKS else "system.img", lambda: opener(source, "rb"))
    elif normalized(source.name, slot) and not source.name.endswith(".zip"):
        # Before the TAR probe: raw super/ext4 images start with zero blocks,
        # which tarfile accepts as an empty archive.
        add(source.name, lambda: source.open("rb"))
    elif tarfile.is_tarfile(source):
        with tarfile.open(source, "r:*") as archive:
            for info in archive:
                normalized(info.name, slot)
                check(not info.issym() and not info.islnk() and not info.isdev(), "TAR links/devices are not accepted")
                if info.isfile() and normalized(info.name, slot):
                    add(info.name, lambda info=info: archive.extractfile(info))
            finish_chunks()
    else:
        add(source.name if normalized(source.name, slot) else "system.img", lambda: source.open("rb"))
    check(any(dest.iterdir()), "No recognized Android image components found")


def image_format(path):
    with Path(path).open("rb") as src:
        data = src.read(4096)
    if data[:4] == b"\x3a\xff\x26\xed": return "android-sparse"
    if data[:4] == b"QFI\xfb": return "qcow2"
    if data[:8] == b"ANDROID!": return "android-boot"
    if data[56:60] == b"ARMd": return "arm64-kernel"
    if data[:2] == b"\x1f\x8b":
        with gzip.open(path, "rb") as stream:
            if stream.read(64)[56:60] == b"ARMd": return "arm64-kernel-gzip"
    if data[1080:1082] == b"\x53\xef": return "ext4"
    if data[512:520] == b"EFI PART": return "gpt"
    if data[1024:1028] == b"\xe2\xe1\xf5\xe0": return "erofs"
    if data[:4] == b"CrAU": return "ota-payload"
    return "raw/unknown"


def read_exact(src, n):
    data = src.read(n)
    check(len(data) == n, "Truncated Android image")
    return data


def raw_runs(src):
    """Yield (offset, data) for the stored runs of a raw or Android sparse stream.

    Holes are skipped; the last item is (total_size, b"")."""
    head = src.read(28)
    if head[:4] != b"\x3a\xff\x26\xed":
        offset = 0
        while head:
            yield offset, head
            offset += len(head)
            head = src.read(4 * 1024**2)
        yield offset, b""
        return
    check(len(head) == 28, "Truncated Android image")
    magic, major, minor, header, chunk_header, block, blocks, chunks, checksum = struct.unpack("<I4H4I", head)
    check(major == 1 and header >= 28 and chunk_header >= 12, "Invalid sparse header")
    check(4 <= block <= 1024**2 and block % 4 == 0 and 0 < blocks <= LIMIT // block and
          0 < chunks <= 10_000_000, "Invalid sparse dimensions")
    read_exact(src, header - 28)
    written = 0
    for _ in range(chunks):
        kind, reserved, count, total = struct.unpack("<2H2I", read_exact(src, 12))
        check(total >= chunk_header and count <= blocks - written // block, "Sparse block overflow")
        read_exact(src, chunk_header - 12)
        size, payload = count * block, total - chunk_header
        if kind == 0xcac1:
            check(payload == size, "Sparse RAW size mismatch")
            remaining = size
            while remaining:
                data = read_exact(src, min(remaining, 4 * 1024**2))
                yield written + size - remaining, data
                remaining -= len(data)
        elif kind == 0xcac2:
            check(payload == 4, "Sparse FILL size mismatch")
            fill = read_exact(src, 4)
            if fill != b"\0" * 4:
                buffer = fill * (256 * 1024)
                remaining = size
                while remaining:
                    data = buffer[:min(remaining, len(buffer))]
                    yield written + size - remaining, data
                    remaining -= len(data)
        elif kind == 0xcac3:
            check(payload == 0, "Sparse DONT_CARE size mismatch")
        elif kind == 0xcac4:
            check(count == 0 and payload == 4, "Sparse CRC block mismatch")
            read_exact(src, 4)
        else:
            raise ValueError(f"Unknown sparse chunk: {kind:x}")
        written += size
    check(written == block * blocks, "Sparse total size mismatch")
    yield written, b""


def unsparse(source, dest):
    with Path(source).open("rb") as src, Path(dest).open("xb") as out:
        check(src.read(4) == b"\x3a\xff\x26\xed", "Invalid sparse header")
        src.seek(0)
        for offset, data in raw_runs(src):
            out.seek(offset)
            out.write(data)
        check(src.read(1) == b"", "Sparse total size mismatch")
        out.truncate(offset)


def lp_partitions(head, slot):
    """Read super's primary LP metadata: {name: (size, [(logical, length, physical)])}."""
    check(len(head) >= 3 * 4096 + 128, "super.img is too small for dynamic-partition metadata")
    magic, _ = struct.unpack_from("<2I", head, 4096)
    check(magic == 0x616c4467, "super.img has no dynamic-partition geometry")
    max_size, slots, block_size = struct.unpack_from("<3I", head, 4096 + 40)
    check(512 <= max_size <= 1024**2 and max_size % 512 == 0 and 1 <= slots <= 3 and
          block_size % 512 == 0 and len(head) >= 3 * 4096 + max_size, "Invalid dynamic-partition geometry")
    base = 3 * 4096
    magic, major, minor, header_size = struct.unpack_from("<I2HI", head, base)
    tables_size = struct.unpack_from("<I", head, base + 44)[0]
    check(magic == 0x414c5030 and major == 10 and 128 <= header_size and
          header_size + tables_size <= max_size, "Unsupported dynamic-partition metadata")
    header = bytearray(head[base:base + header_size])
    header[12:44] = bytes(32)
    tables = head[base + header_size:base + header_size + tables_size]
    check(hashlib.sha256(header).digest() == head[base + 12:base + 44] and
          hashlib.sha256(tables).digest() == head[base + 48:base + 80],
          "Dynamic-partition metadata checksum mismatch")
    descriptors = struct.unpack_from("<12I", head, base + 80)

    def table(index, entry_size):
        offset, count, size = descriptors[index * 3:index * 3 + 3]
        check(size >= entry_size and offset + count * size <= len(tables), "Corrupt dynamic-partition table")
        return [tables[offset + i * size:offset + (i + 1) * size] for i in range(count)]

    extents = [struct.unpack_from("<QIQI", entry) for entry in table(1, 24)]
    partitions = {}
    for entry in table(0, 52):
        name = entry[:36].split(b"\0")[0].decode("ascii", "replace")
        attributes, first, count, group = struct.unpack_from("<4I", entry, 36)
        check(re.fullmatch(r"[a-z0-9_]{1,36}", name) is not None and first + count <= len(extents),
              f"Corrupt dynamic-partition entry {name!r}")
        if name.endswith(("_a", "_b")):
            if not name.endswith("_" + slot):
                continue
            name = name[:-2]
        logical, runs = 0, []
        for sectors, kind, physical, device in extents[first:first + count]:
            check(device == 0 and kind in (0, 1), f"{name}: multi-device or unknown extents are not supported")
            if kind == 0:
                runs.append((logical, sectors * 512, physical * 512))
            logical += sectors * 512
        check(name not in partitions, f"Duplicate dynamic partition {name}")
        partitions[name] = (logical, runs)
    return partitions


def extract_super(openers, target_for, slot, budget):
    """Stream the VM-relevant logical partitions out of super (or its ordered sparse
    chunks) without writing super itself. Returns the bytes allocated."""
    head, pending, routes, files = bytearray(), [], None, []

    def start():
        nonlocal routes
        routes, allocated = [], 0
        for name, (size, runs) in sorted(lp_partitions(bytes(head), slot).items()):
            if name + ".img" not in DISKS or size == 0:
                continue
            allocated += size
            check(allocated <= budget, "Image exceeds the 48 GiB conversion limit")
            out = target_for(name + ".img").open("xb")
            files.append(out)
            out.truncate(size)
            routes += [(physical, physical + length, out, logical) for logical, length, physical in runs]
        check(files, f"super.img has no system/vendor/product partitions for slot {slot}")
        return allocated

    def write(offset, data):
        end = offset + len(data)
        for start_at, stop, out, logical in routes:
            if start_at < end and offset < stop:
                a, b = max(start_at, offset), min(stop, end)
                out.seek(logical + a - start_at)
                out.write(data[a - offset:b - offset])

    allocated = 0
    try:
        for opener in openers:
            with opener() as stream:
                for offset, data in raw_runs(stream):
                    if routes is not None:
                        write(offset, data)
                        continue
                    pending.append((offset, data))
                    if offset >= len(head) and data:
                        head.extend(bytes(offset - len(head)))
                        head.extend(data)
                    if len(head) >= 4096 + 52:
                        max_size = struct.unpack_from("<I", head, 4096 + 40)[0]
                        if len(head) >= 3 * 4096 + min(max_size, 1024**2):
                            allocated = start()
                            for item in pending:
                                write(*item)
                            pending.clear()
        if routes is None:
            allocated = start()
            for item in pending:
                write(*item)
    finally:
        for out in files:
            out.close()
    return allocated


def tool(name):
    path = shutil.which(name)
    check(path is not None, f"Install {name} on this computer, then retry; no ROM scripts will be executed")
    return path


def run(args, timeout=1800, **kwargs):
    return subprocess.run(args, check=True, timeout=timeout, **kwargs)


def tree(root):
    """Describe a mounted partition: ({path: metadata}, entries, 4K blocks an ext4 copy needs).

    Metadata is type, permission bits, owner, rdev, every xattr (SELinux label,
    capabilities), symlink target, content SHA-256 and hardlink grouping."""
    root = Path(root)
    entries, blocks, first = {}, 0, {}
    listxattr = getattr(os, "listxattr", None)
    paths = [root]
    for parent, dirs, files in os.walk(root):  # never follows directory symlinks
        paths += [Path(parent, name) for name in dirs + files]
    for path in sorted(paths):
        rel = path.relative_to(root).as_posix()
        st = path.lstat()
        xattrs = {k: os.getxattr(path, k, follow_symlinks=False)
                  for k in sorted(listxattr(path, follow_symlinks=False))} if listxattr else {}
        info = [stat.S_IFMT(st.st_mode), stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, xattrs]
        # 256-byte inodes hold ~90 bytes of xattrs; the rest needs its own block.
        blocks += sum(len(k) + len(v) + 16 for k, v in xattrs.items()) > 90
        if stat.S_ISLNK(st.st_mode):
            target = os.readlink(path)
            info.append(target)
            blocks += len(target) >= 60
        elif stat.S_ISREG(st.st_mode):
            digest = hashlib.sha256()
            with path.open("rb") as src:
                while data := src.read(1024**2):
                    digest.update(data)
            key = (st.st_dev, st.st_ino)
            info += [st.st_size, digest.hexdigest(), first.setdefault(key, rel) if st.st_nlink > 1 else None]
            if first.get(key, rel) == rel:
                blocks += -(-st.st_size // 4096)
        elif stat.S_ISDIR(st.st_mode):
            blocks += 1 + len(os.listdir(path)) * 64 // 4096
        elif stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode):
            info.append(st.st_rdev)
        entries[rel] = info
    return entries, len(paths), blocks


def erofs_to_ext4(path):
    """Rebuild an EROFS partition as ext4 with identical metadata (Linux, root).

    The App, engine and guest fstab mount ext4 only. mke2fs -d copies owner,
    mode, xattrs and hardlinks straight from a read-only mount (nothing is
    extracted to disk), and every entry is compared before the copy is used."""
    check(sys.platform.startswith("linux") and os.geteuid() == 0,
          f"{path.name} is EROFS; rebuilding it as ext4 needs Linux as root (WSL works)")
    mke2fs, e2fsck, resize2fs, debugfs = (tool(name) for name in ("mke2fs", "e2fsck", "resize2fs", "debugfs"))
    print(f"Rebuilding {path.name} from EROFS as ext4 (metadata verified)...", file=sys.stderr)
    out, source, copy = path.with_suffix(".ext4"), path.with_suffix(".erofs-mnt"), path.with_suffix(".ext4-mnt")
    source.mkdir()
    copy.mkdir()
    run(["mount", "-t", "erofs", "-o", "loop,ro", str(path), str(source)])
    try:
        expected, entries, blocks = tree(source)
        inodes = entries + entries // 20 + 256
        # Data + 256-byte inode tables + per-group metadata, with slack that
        # resize2fs -M trims. Features match Android-built ext4 images.
        total = blocks + blocks // 12 + inodes // 16 + 4096
        with out.open("xb") as image:
            image.truncate(total * 4096)
        run([mke2fs, "-q", "-F", "-b", "4096", "-I", "256", "-N", str(inodes), "-m", "0",
             "-O", "^resize_inode,extent,huge_file,uninit_bg,dir_nlink,extra_isize",
             "-E", "root_owner=0:0", "-d", str(source), str(out), str(total)], timeout=4 * 3600)
        label = expected["."][4].get("security.selinux")
        if "lost+found" not in expected and label:
            # Android labels lost+found like the partition root.
            value = path.with_suffix(".label")
            check('"' not in str(value), f"Unsupported character in work path: {value}")
            value.write_bytes(label)
            run([debugfs, "-w", "-R", f'ea_set -f "{value}" /lost+found security.selinux', str(out)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            value.unlink()
        run([e2fsck, "-fn", str(out)], stdout=subprocess.DEVNULL)
        run([resize2fs, "-M", str(out)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run([e2fsck, "-fn", str(out)], stdout=subprocess.DEVNULL)
        run(["mount", "-t", "ext4", "-o", "loop,ro", str(out), str(copy)])
        try:
            actual = tree(copy)[0]
        finally:
            run(["umount", str(copy)])
        # mke2fs always adds lost+found; Android-built images carry one too.
        if "lost+found" not in expected:
            added = actual.pop("lost+found", None)
            check(not label or added and added[4].get("security.selinux") == label,
                  f"{path.name}: lost+found did not get the root SELinux label")
        check(actual == expected, f"{path.name}: ext4 rebuild differs from the EROFS original")
    finally:
        run(["umount", str(source)])
        source.rmdir()
        copy.rmdir()
    out.replace(path)


def dat_image(data, transfers, target):
    lines = Path(transfers).read_text(encoding="ascii").splitlines()
    check(len(lines) >= 2 and lines[0] in ("1", "2", "3", "4"), "Unsupported transfer-list version")
    commands = lines[2 if lines[0] == "1" else 4:]
    check(commands, "Empty transfer list")
    max_end = 0
    plan = []
    new_ranges = []
    for line in commands:
        words = line.split()
        check(len(words) == 2 and words[0] in ("new", "zero", "erase"),
              "Incremental OTA needs its exact old partitions; only full new/zero/erase transfers are supported")
        ranges = [int(x) for x in words[1].split(",")]
        check(ranges and ranges[0] == len(ranges) - 1 and ranges[0] % 2 == 0, "Invalid transfer ranges")
        for start, end in zip(ranges[1::2], ranges[2::2]):
            check(0 <= start < end <= LIMIT // 4096, "Invalid transfer bounds")
            max_end = max(max_end, end)
            if words[0] == "new":
                plan.append((start, end))
                new_ranges.append((start, end))
    ordered = sorted(new_ranges)
    check(all(ordered[i][0] >= ordered[i-1][1] for i in range(1, len(ordered))), "Overlapping new-data ranges")
    check(new_ranges, "Transfer list contains no new partition data")
    with Path(data).open("rb") as src, Path(target).open("xb") as out:
        for start, end in plan:
            out.seek(start * 4096)
            remaining = (end - start) * 4096
            while remaining:
                part = read_exact(src, min(remaining, 1024**2))
                out.write(part)
                remaining -= len(part)
        # A full OTA's erase/zero ranges describe old contents; the fresh output
        # is already zero-filled outside its new ranges. They can overlap erase
        # hints and arrive before lower new ranges, so do not require global order.
        check(src.read(1) == b"", "Unused bytes in new.dat")
        out.truncate(max_end * 4096)


def convert_components(root, slot):
    for path in list(root.glob("*.new.dat.br")):
        target = path.with_suffix("")
        check(not target.exists(), f"Duplicate partition: {target.name}")
        with target.open("xb") as out:
            run([tool("brotli"), "-d", "-c", str(path)], stdout=out)
    for path in list(root.glob("*.new.dat")):
        name = path.name.removesuffix(".new.dat")
        check(name + ".img" in DISKS, f"Unsupported transfer partition: {name}")
        dat_image(path, root / (name + ".transfer.list"), root / (name + ".img"))
    for path in list(root.glob("*.img")):
        kind = image_format(path)
        if kind == "android-sparse":
            raw = path.with_suffix(".raw")
            unsparse(path, raw)
            raw.replace(path)
        elif kind == "qcow2":
            qemu = tool("qemu-img")
            info = json.loads(run([qemu, "info", "--output=json", str(path)], capture_output=True).stdout)
            text = json.dumps(info)
            check(not info.get("backing-filename") and '"data-file"' not in text and
                  info.get("virtual-size", LIMIT + 1) <= LIMIT and not info.get("encrypted"),
                  "QCOW2 backing/external-data/encrypted images require a standalone export from the original VM")
            raw = path.with_suffix(".raw")
            run([qemu, "convert", "-f", "qcow2", "-O", "raw", str(path), str(raw)])
            raw.replace(path)
    # super.img is split into logical partitions by collect() itself.
    extracted = root / "extracted"
    if (root / "payload.bin").exists():
        extracted.mkdir()
        run([tool("payload-dumper-go"), "-o", str(extracted), str(root / "payload.bin")])
        # Only collect the selected slot; never silently merge two images.
        collect(extracted, root, slot)
        # Logical partitions from a payload may themselves still be sparse.
        for path in root.glob("*.img"):
            if image_format(path) == "android-sparse":
                raw = path.with_suffix(".raw")
                unsparse(path, raw)
                raw.replace(path)


def validate(root, profile):
    check(all(not (root / ("vmhost_guest_" + old)).exists() or profile == old for old in ("p9", "p71")),
          "Profile conflicts with existing p9/p71 boot markers")
    required = {"kernel", "system.img", "userdata.img"}
    if profile == "p9": required |= {"vendor.img", "encryptionkey.img"}
    elif profile == "p71": required.add("ramdisk.img")
    else: required |= {"ramdisk.img", "vendor.img", "product.img", "system_ext.img", "metadata.img"}
    missing = sorted(n for n in required if not (root / n).is_file() or not (root / n).stat().st_size)
    check(not missing, "Missing virtual-machine components: " + ", ".join(missing) +
          ". A phone boot.img/kernel is not a replacement for a ranchu kernel/vendor. See --base and the adaptation guide.")
    kernel_format = image_format(root / "kernel")
    check(kernel_format in ("arm64-kernel", "arm64-kernel-gzip"), "Need a raw/gzip ARM64 ranchu Linux Image; not phone boot.img/x86")
    if kernel_format == "arm64-kernel-gzip":
        with gzip.open(root / "kernel", "rb") as src:
            total = 0
            while data := src.read(1024**2):
                total += len(data)
                check(total <= 512 * 1024**2, "Kernel expands beyond 512 MiB")
    for name in DISKS:
        path = root / name
        if not path.exists() or name == "encryptionkey.img": continue
        allowed = {"gpt"} if profile == "p9" and name == "system.img" else {"ext4"}
        if profile == "p9" and name == "vendor.img": allowed.add("gpt")
        placeholder = (name == "userdata.img" and profile in ("p11", "p13") and path.stat().st_size == 1048576
                       and path.read_bytes() == b"\0" * 1048576)
        check(placeholder or image_format(path) in allowed,
              f"{name}: {image_format(path)} is incompatible with {profile}; expected {sorted(allowed)}")


def properties(values):
    def escape(value):
        output = []
        for c in str(value):
            if c in "\\\n\r\t":
                output.append({"\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t"}[c])
            elif ord(c) > 127:
                encoded = c.encode("utf-16-be")
                output.extend(f"\\u{int.from_bytes(encoded[i:i+2], 'big'):04x}" for i in range(0, len(encoded), 2))
            elif c in "=: #!":
                output.append("\\" + c)
            else:
                output.append(c)
        return "".join(output)
    return "\n".join(f"{k}={escape(v)}" for k, v in values.items()) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["inspect", "prepare"])
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--profile", choices=["p71", "p9", "p11", "p13"])
    parser.add_argument("--name", default="External Android")
    parser.add_argument("--slot", choices=["a", "b"], default="a")
    parser.add_argument("--base", type=Path, help="An already adapted virtual-hardware bundle/directory; never a live VM directory")
    parser.add_argument("--experimental-system-replacement", action="store_true",
                        help="Explicitly try source system.img on base's kernel/vendor/data. Does not guarantee boot.")
    args = parser.parse_args(argv)
    with tempfile.TemporaryDirectory(prefix="vmhost-image-") as work:
        root = Path(work) / "source"
        collect(args.source, root, args.slot)
        if args.action == "inspect":
            print(json.dumps({"files": {p.name: {"bytes": p.stat().st_size, "format": image_format(p)} for p in root.iterdir()},
                              "boot_verified": False,
                              "note": "Container recognition does not validate kernel/vendor/HAL compatibility"}, indent=2))
            return
        check(args.profile and args.output, "prepare requires --profile and --output")
        check(not args.output.exists(), "Output already exists; choose a new filename")
        check(bool(args.base) == args.experimental_system_replacement,
              "--base requires --experimental-system-replacement (and vice versa); hardware adaptation is experimental")
        convert_components(root, args.slot)
        if args.base:
            check(not (args.base / "snapshot.state").exists() and not (args.base / "snapshots").exists(),
                  "Never use a live VM/snapshot directory as the base; use its read-only image templates")
            base = Path(work) / "base"
            collect(args.base, base, args.slot)
            convert_components(base, args.slot)
            validate(base, args.profile)
            check((root / "system.img").is_file(), "Source has no system.img after partition extraction")
            # system_ext/product are Treble's system side (framework extensions,
            # SystemUI, their sepolicy halves) and ship as a set with system.
            # Keep the virtual kernel/vendor/ramdisk and fresh writable templates.
            # Do not import a phone's encrypted data or hardware-specific vendor.
            for name in ("system.img", "system_ext.img", "product.img"):
                if (root / name).is_file():
                    os.replace(root / name, base / name)
            root = base
        for name in ("system.img", "system_ext.img", "product.img", "vendor.img"):
            if (root / name).is_file() and image_format(root / name) == "erofs":
                erofs_to_ext4(root / name)
        validate(root, args.profile)
        if args.profile in ("p9", "p71"):
            (root / ("vmhost_guest_" + args.profile)).touch()
        description = properties(dict(schema=1, arch="arm64", board="ranchu", profile=args.profile,
            api={"p71":25,"p9":28,"p11":30,"p13":33}[args.profile], name=args.name,
            experimental="true"))  # No third-party guest is marked boot-tested by a converter.
        (root / "vmhost-image.properties").write_text(description, encoding="ascii")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".vmhost-import-", suffix=".zip", dir=args.output.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=1, allowZip64=True) as archive:
                for path in sorted(root.iterdir()):
                    if path.name in BUNDLE:
                        archive.write(path, path.name)
            # Atomic exclusive publication: a concurrent caller cannot replace output.
            os.link(temporary, args.output)
        finally:
            Path(temporary).unlink(missing_ok=True)
        print(json.dumps({"output": str(args.output), "profile": args.profile,
                          "experimental": True, "boot_verified": False}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile, tarfile.TarError) as exc:
        raise SystemExit(f"Image conversion failed: {exc}")
