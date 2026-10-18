import io
import gzip
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zipfile

import import_android_image as image


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self): self.temp.cleanup()

    def bundle(self, name="base"):
        root = self.root / name
        root.mkdir()
        kernel = bytearray(64)
        kernel[56:60] = b"ARMd"
        (root / "kernel").write_bytes(kernel)
        (root / "ramdisk.img").write_bytes(b"ramdisk")
        for name in image.DISKS - {"encryptionkey.img"}:
            raw = bytearray(4096)
            raw[1080:1082] = b"\x53\xef"
            (root / name).write_bytes(raw)
        return root

    def sparse(self, chunks, blocks=4):
        return (struct.pack("<I4H4I", 0xed26ff3a, 1, 0, 28, 12, 4, blocks, len(chunks), 0) +
                b"".join(struct.pack("<2H2I", kind, 0, count, 12+len(data)) + data for kind, count, data in chunks))

    def archive(self, files, name="input.zip"):
        path = self.root / name
        with zipfile.ZipFile(path, "w") as out:
            for name, data in files.items(): out.writestr(name, data)
        return path

    def test_sparse_mixed(self):
        src, dst = self.root / "sparse", self.root / "raw"
        src.write_bytes(self.sparse([(0xcac1,1,b"1234"),(0xcac2,2,b"abcd"),(0xcac3,1,b"")]))
        image.unsparse(src, dst)
        self.assertEqual(dst.read_bytes(), b"1234abcdabcd\0\0\0\0")

    def test_sparse_overflow_truncation_and_bad_type(self):
        for i, chunks in enumerate([[(0xcac3,5,b"")], [(0xcac1,4,b"a")], [(1,4,b"")]]):
            src = self.root / f"bad{i}"
            src.write_bytes(self.sparse(chunks))
            with self.assertRaises(ValueError): image.unsparse(src, self.root / f"raw{i}")

    def test_do_not_overwrite_sparse_target(self):
        src, dst = self.root / "src", self.root / "dst"
        src.write_bytes(self.sparse([(0xcac3,4,b"")]))
        dst.write_text("keep")
        with self.assertRaises(FileExistsError): image.unsparse(src, dst)
        self.assertEqual(dst.read_text(), "keep")

    def test_nested_kernel_alias_and_slot_selection(self):
        source = self.archive({"images/kernel-ranchu": b"k", "images/system_a.img": b"a", "images/system_b.img": b"b"})
        target = self.root / "out"
        image.collect(source, target, "b")
        self.assertEqual((target / "system.img").read_bytes(), b"b")
        self.assertTrue((target / "kernel").exists())

    def test_reject_zip_traversal_and_ambiguous_partitions(self):
        for i, files in enumerate([{"../x/system.img": b"x"}, {"a/system.img": b"a", "b/system.img": b"b"}]):
            source = self.archive(files, f"in{i}.zip")
            with self.assertRaises(ValueError): image.collect(source, self.root / f"out{i}")

    def test_reject_zip_symlink(self):
        source = self.root / "symlink.zip"
        with zipfile.ZipFile(source, "w") as out:
            entry = zipfile.ZipInfo("system.img")
            entry.external_attr = 0o120777 << 16
            out.writestr(entry, "/etc/passwd")
        with self.assertRaises(ValueError): image.collect(source, self.root / "out")

    def test_new_dat_erase_hint_then_lower_new(self):
        dat, listing, target = self.root / "dat", self.root / "transfer", self.root / "raw"
        dat.write_bytes(b"a" * 4096 + b"b" * 4096)
        listing.write_text("4\n2\n0\n0\nerase 2,0,4\nnew 4,0,1,2,3\nzero 2,3,4\n")
        image.dat_image(dat, listing, target)
        self.assertEqual(target.read_bytes(), b"a"*4096+b"\0"*4096+b"b"*4096+b"\0"*4096)

    def test_incremental_ota_is_not_silently_faked(self):
        dat, listing = self.root / "dat", self.root / "transfer"
        dat.write_bytes(b"x")
        listing.write_text("4\n1\n0\n0\nmove 2,0,1\n")
        with self.assertRaisesRegex(ValueError, "Incremental OTA"):
            image.dat_image(dat, listing, self.root / "raw")

    def test_overlapping_new_ranges_rejected(self):
        dat, listing = self.root / "dat", self.root / "transfer"
        dat.write_bytes(b"a" * 8192)
        listing.write_text("4\n2\n0\n0\nnew 4,0,1,0,1\n")
        with self.assertRaisesRegex(ValueError, "Overlapping"):
            image.dat_image(dat, listing, self.root / "raw")

    def test_payload_missing_tool_is_actionable(self):
        root = self.root / "payload"
        root.mkdir()
        (root / "payload.bin").write_bytes(b"CrAU")
        with mock.patch.object(image.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "payload-dumper-go"): image.convert_components(root, "a")

    def test_backing_qcow_never_converted(self):
        root = self.root / "qcow"
        root.mkdir()
        (root / "system.img").write_bytes(b"QFI\xfb" + b"\0"*4096)
        report = mock.Mock(stdout=json.dumps({"backing-filename":"private", "virtual-size":4096}).encode())
        with mock.patch.object(image, "tool", return_value="qemu-img"), mock.patch.object(image, "run", return_value=report) as run:
            with self.assertRaisesRegex(ValueError, "standalone export"): image.convert_components(root, "a")
            self.assertEqual(run.call_count, 1)

    def test_prepare_and_existing_output_preserved(self):
        base = self.bundle()
        output = self.root / "bundle.zip"
        image.main(["prepare", str(base), "--profile", "p11", "--output", str(output), "--name", "Third party"])
        with zipfile.ZipFile(output) as archive:
            props = archive.read("vmhost-image.properties")
            self.assertIn(b"board=ranchu", props)
            self.assertIn(b"experimental=true", props)
        previous = output.read_bytes()
        with self.assertRaisesRegex(ValueError, "already exists"):
            image.main(["prepare", str(base), "--profile", "p11", "--output", str(output)])
        self.assertEqual(output.read_bytes(), previous)

    def test_experimental_replacement_keeps_virtual_vendor_and_clean_data(self):
        base = self.bundle()
        source = self.bundle("phone")
        with (source / "system.img").open("r+b") as out: out.write(b"phone-system")
        (source / "vendor.img").write_bytes(b"phone-hardware")
        (source / "userdata.img").write_bytes(b"phone-encrypted-data")
        original = {p.name:p.read_bytes() for p in base.iterdir()}
        target = self.root / "adapted.zip"
        image.main(["prepare", str(source), "--profile", "p11", "--output", str(target),
                    "--base", str(base), "--experimental-system-replacement"])
        with zipfile.ZipFile(target) as archive:
            self.assertEqual(archive.read("vendor.img"), original["vendor.img"])
            self.assertEqual(archive.read("userdata.img"), original["userdata.img"])
            self.assertTrue(archive.read("system.img").startswith(b"phone-system"))
        self.assertEqual({p.name:p.read_bytes() for p in base.iterdir()}, original)

    def test_base_requires_explicit_experiment(self):
        base = self.bundle()
        with self.assertRaisesRegex(ValueError, "requires --experimental"):
            image.main(["prepare", str(base), "--profile", "p11", "--output", str(self.root/"out.zip"), "--base", str(base)])

    def test_live_vm_base_refused(self):
        base = self.bundle()
        (base / "snapshot.state").write_text("do not touch")
        with self.assertRaisesRegex(ValueError, "live VM"):
            image.main(["prepare", str(base), "--profile", "p11", "--output", str(self.root/"out.zip"),
                        "--base", str(base), "--experimental-system-replacement"])

    def test_wrong_arch_and_erofs_refused(self):
        base = self.bundle()
        (base / "kernel").write_bytes(b"ANDROID!" + b"\0"*4096)
        with self.assertRaisesRegex(ValueError, "ARM64"): image.validate(base, "p11")

    def test_properties_cannot_inject_board_or_api(self):
        text = image.properties({"name":"中文\nboard=phone\\x😀"})
        self.assertEqual(len(text.splitlines()), 1)
        self.assertIn("\\nboard\\=phone", text)
        self.assertIn("\\ud83d\\ude00", text)

    def test_conflicting_profile_refused(self):
        base = self.bundle()
        (base / "vmhost_guest_p71").touch()
        with self.assertRaisesRegex(ValueError, "conflicts"):
            image.validate(base, "p11")

    def test_real_sdk_gzip_kernel_and_zero_placeholder_layout(self):
        base = self.bundle()
        (base / "kernel").write_bytes(gzip.compress((base / "kernel").read_bytes()))
        (base / "userdata.img").write_bytes(b"\0"*1048576)
        image.validate(base, "p11")
        self.assertEqual(image.image_format(base / "kernel"), "arm64-kernel-gzip")
        broken = bytearray((base / "kernel").read_bytes())
        broken[-8] ^= 1
        (base / "kernel").write_bytes(broken)
        with self.assertRaises((ValueError, OSError)): image.validate(base, "p11")


if __name__ == "__main__": unittest.main()
