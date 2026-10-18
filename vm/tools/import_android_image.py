#!/usr/bin/env python3
"""Inspect/normalize third-party Android images; extraction is not hardware emulation.

Standard library only. Optional installed tools: lpunpack, payload-dumper-go,
brotli, qemu-img. Never executes programs or flash scripts from a ROM archive.
"""
import argparse
import gzip
import json
import lzma
import os
from pathlib import Path
import shutil
import struct
import subprocess
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

    def add(name, stream):
        nonlocal total
        name = normalized(name, slot)
        if name is None:
            return
        target = dest / name
        check(not target.exists(), f"Multiple copies of {name}; select one slot/architecture first")
        with target.open("xb") as out:
            total += copy_stream(stream, out, LIMIT - total)

    if source.is_dir():
        for path in source.rglob("*"):
            check(not path.is_symlink(), f"Symlinks are not accepted: {path.name}")
            if path.is_file():
                with path.open("rb") as stream:
                    add(path.relative_to(source).as_posix(), stream)
    elif zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as archive:
            for info in archive.infolist():
                check((info.external_attr >> 16) & 0o170000 != 0o120000, "ZIP symlinks are not accepted")
                if not info.is_dir():
                    # Validate every path, even entries we do not extract.
                    name = normalized(info.filename, slot)
                    if name:
                        with archive.open(info) as stream:
                            add(info.filename, stream)
    elif source.name.endswith((".img.xz", ".img.gz")):
        opener = lzma.open if source.suffix == ".xz" else gzip.open
        with opener(source, "rb") as stream:
            add(source.stem if source.stem in DISKS else "system.img", stream)
    elif tarfile.is_tarfile(source):
        with tarfile.open(source, "r:*") as archive:
            for info in archive:
                normalized(info.name, slot)
                check(not info.issym() and not info.islnk() and not info.isdev(), "TAR links/devices are not accepted")
                if info.isfile() and normalized(info.name, slot):
                    with archive.extractfile(info) as stream:
                        add(info.name, stream)
    else:
        with source.open("rb") as stream:
            add(source.name if normalized(source.name, slot) else "system.img", stream)
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


def unsparse(source, dest):
    with Path(source).open("rb") as src, Path(dest).open("xb") as out:
        magic, major, minor, header, chunk_header, block, blocks, chunks, checksum = struct.unpack("<I4H4I", read_exact(src, 28))
        check(magic == 0xed26ff3a and major == 1 and header >= 28 and chunk_header >= 12,
              "Invalid sparse header")
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
                    data = read_exact(src, min(remaining, 1024**2))
                    out.write(data)
                    remaining -= len(data)
            elif kind == 0xcac2:
                check(payload == 4, "Sparse FILL size mismatch")
                fill = read_exact(src, 4)
                if fill == b"\0" * 4:
                    out.seek(size, 1)
                else:
                    buffer = fill * (256 * 1024)
                    remaining = size
                    while remaining:
                        data = buffer[:min(remaining, len(buffer))]
                        out.write(data)
                        remaining -= len(data)
            elif kind == 0xcac3:
                check(payload == 0, "Sparse DONT_CARE size mismatch")
                out.seek(size, 1)
            elif kind == 0xcac4:
                check(count == 0 and payload == 4, "Sparse CRC block mismatch")
                read_exact(src, 4)
            else:
                raise ValueError(f"Unknown sparse chunk: {kind:x}")
            written += size
        check(written == block * blocks and src.read(1) == b"", "Sparse total size mismatch")
        out.truncate(written)


def tool(name):
    path = shutil.which(name)
    check(path is not None, f"Install {name} on this computer, then retry; no ROM scripts will be executed")
    return path


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=1800, **kwargs)


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
    extracted = root / "extracted"
    if (root / "payload.bin").exists():
        check(not (root / "super.img").exists(), "Both payload.bin and super.img supplied; choose one source")
        extracted.mkdir()
        run([tool("payload-dumper-go"), "-o", str(extracted), str(root / "payload.bin")])
    elif (root / "super.img").exists():
        extracted.mkdir()
        run([tool("lpunpack"), str(root / "super.img"), str(extracted)])
    if extracted.exists():
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
            # Keep the virtual kernel/vendor/ramdisk and fresh writable templates.
            # Do not import a phone's encrypted data or hardware-specific vendor.
            shutil.copyfile(root / "system.img", base / "system.img")
            root = base
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
