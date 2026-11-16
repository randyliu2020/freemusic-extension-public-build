"""Structural tests; --ipa additionally checks packaging the actual original IPA.

Synthetic dylib fixtures are never offered as a playable extension. Device
loading and real compiled-extension tests are separate from this byte-level QA.
"""
from __future__ import annotations

import argparse
import io
from pathlib import Path
import shutil
import stat
import struct
import sys
import unittest
import uuid
import zipfile

import artwork_patch as artwork
import package_extension as package

IPA = None


def fixture(*, filetype=6, signed=True, encrypted=False, tight_padding=False):
    text = bytearray(struct.pack("<II16sQQQQIIII", 0x19, 152, b"__TEXT", 0, 0x4000, 0, 0x500, 5, 5, 1, 0))
    text += struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0x400, 16, 0x400, 2, 0, 0, 0x80000400, 0, 0, 0)
    linkedit = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__LINKEDIT", 0x4000, 0x4000, 0x500, 0x200, 1, 1, 0, 0)
    commands = [bytes(text), linkedit, struct.pack("<6I", 0x32, 24, 2, 17 << 16, 27 << 16, 0),
                struct.pack("<6I", 2, 24, 0x500, 1, 0x510, 16)]
    if filetype == 6:
        identity = bytearray(package.dylib_load_command())
        struct.pack_into("<I", identity, 0, 0xD)
        commands.append(bytes(identity))
    if encrypted:
        commands.append(struct.pack("<6I", 0x2C, 24, 0x400, 16, 1, 0))
    if signed:
        commands.append(struct.pack("<4I", 0x1D, 16, 0x600, 0x100))
    end = 32 + sum(map(len, commands))
    first_data = end if tight_padding else 0x400
    if tight_padding:
        text = bytearray(commands[0])
        struct.pack_into("<Q", text, 72 + 32, first_data)
        struct.pack_into("<I", text, 72 + 48, first_data)
        commands[0] = bytes(text)
    binary = bytearray(0x700)
    struct.pack_into("<8I", binary, 0, 0xFEEDFACF, 0x0100000C, 0, filetype, len(commands), end - 32, 0, 0)
    binary[32:end] = b"".join(commands)
    binary[first_data:first_data + 16] = bytes.fromhex("c0035fd6") * 4
    binary[0x500:0x520] = bytes(range(32))
    if signed:
        binary[0x600:0x700] = b"S" * 0x100
    return bytes(binary)


def zip_bytes(entries):
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w") as archive:
        for name, content in entries:
            if isinstance(name, str):
                raw_name = name
                name = zipfile.ZipInfo(raw_name)
                name.filename = raw_name
            archive.writestr(name, content)
    result.seek(0)
    return result


class MachOTests(unittest.TestCase):
    def test_extension_version_matches_injected_requirement(self):
        info = package.parse_macho(fixture(), 6)
        versions = package.validate_extension_dylib(info)
        self.assertEqual(versions["current_version"], 0x10000)
        self.assertEqual(versions["compatibility_version"], 0x10000)
        self.assertEqual(versions["load_required_version"], 0x10000)

    def test_extension_library_older_than_required_is_rejected(self):
        binary = bytearray(fixture())
        identity = next(c for c in package.parse_macho(binary).commands if c.kind == package.LC_ID_DYLIB)
        struct.pack_into("<II", binary, identity.offset + 16, 0, 0)
        with self.assertRaisesRegex(package.PackageError, "lower than the injected load command"):
            package.validate_extension_dylib(package.parse_macho(binary, 6))

    def test_extension_compatibility_above_current_is_rejected(self):
        binary = bytearray(fixture())
        identity = next(c for c in package.parse_macho(binary).commands if c.kind == package.LC_ID_DYLIB)
        struct.pack_into("<II", binary, identity.offset + 16, 0x10000, 0x20000)
        with self.assertRaisesRegex(package.PackageError, "lower than its compatibility_version"):
            package.validate_extension_dylib(package.parse_macho(binary, 6))

    def test_add_dependency_keep_segments_and_code_remove_signature(self):
        original = fixture(filetype=2)
        modified, report = package.rewrite_macho(original, inject=True, expected_type=2)
        before = package.parse_macho(original, 2)
        after = package.parse_macho(modified, 2)
        self.assertEqual(before.segments, after.segments)
        self.assertEqual(len(modified), len(original))
        self.assertEqual(modified[0x400:0x600], original[0x400:0x600])
        self.assertEqual(modified[0x600:0x700], bytes(0x100))
        self.assertFalse(any(c.kind == 0x1D for c in after.commands))
        self.assertEqual([package.command_string(c) for c in after.commands if c.kind == 0xC], [package.DYLIB_NAME])
        self.assertEqual(report["signature_bytes_zeroed"], 0x100)

    def test_unsigned_library_keeps_identity_and_code(self):
        original = fixture(signed=False)
        clean, report = package.rewrite_macho(original, inject=False, expected_type=6)
        self.assertEqual(clean, original)
        self.assertEqual(report["signature_bytes_zeroed"], 0)
        self.assertEqual([package.command_string(c) for c in package.parse_macho(clean).commands if c.kind == 0xD], [package.DYLIB_NAME])

    def test_insufficient_padding_fails_without_relocation(self):
        with self.assertRaisesRegex(package.PackageError, "Insufficient header padding"):
            package.rewrite_macho(fixture(filetype=2, tight_padding=True), inject=True, expected_type=2)

    def test_nonzero_padding_is_not_overwritten(self):
        original = bytearray(fixture(filetype=2))
        end = package.parse_macho(original).command_end
        original[end + 1] = 0xAA
        with self.assertRaisesRegex(package.PackageError, "padding is not all zero"):
            package.rewrite_macho(bytes(original), inject=True, expected_type=2)

    def test_duplicate_injection_fails(self):
        modified, _ = package.rewrite_macho(fixture(filetype=2), inject=True, expected_type=2)
        with self.assertRaisesRegex(package.PackageError, "already present"):
            package.rewrite_macho(modified, inject=True, expected_type=2)

    def test_encrypted_and_non_ios_device_binaries_are_rejected(self):
        with self.assertRaisesRegex(package.PackageError, "Encrypted"):
            package.parse_macho(fixture(encrypted=True))
        original = bytearray(fixture())
        build = next(c for c in package.parse_macho(original).commands if c.kind == 0x32)
        struct.pack_into("<I", original, build.offset + 8, 7)
        with self.assertRaisesRegex(package.PackageError, "iOS-device"):
            package.parse_macho(original)

    def test_signature_overlap_with_live_tables_fails(self):
        original = bytearray(fixture())
        signature = next(c for c in package.parse_macho(original).commands if c.kind == 0x1D)
        struct.pack_into("<II", original, signature.offset + 8, 0x500, 0x100)
        with self.assertRaisesRegex(package.PackageError, "overlaps live"):
            package.rewrite_macho(original, inject=False, expected_type=6)

    def test_malformed_command_and_architecture_rejected(self):
        original = bytearray(fixture())
        struct.pack_into("<I", original, 36, 7)
        with self.assertRaises(package.PackageError):
            package.parse_macho(original)
        original = bytearray(fixture())
        struct.pack_into("<I", original, 4, 0x01000007)
        with self.assertRaises(package.PackageError):
            package.parse_macho(original)


class ArchiveSafetyTests(unittest.TestCase):
    def test_traversal_absolute_windows_and_alias_paths_rejected(self):
        for name in ["../escape", "/absolute", "C:/absolute", "dir\\file", "a//b", "a/./b", "a/../b"]:
            with self.subTest(name=name), zipfile.ZipFile(zip_bytes([(name, b"x")])) as archive:
                with self.assertRaises(package.PackageError):
                    package.safe_zip_entries(archive)

    def test_case_collision_and_file_directory_conflict_rejected(self):
        for entries in [[("A", b"1"), ("a", b"2")], [("folder", b"x"), ("folder/data", b"y")]]:
            with zipfile.ZipFile(zip_bytes(entries)) as archive, self.assertRaises(package.PackageError):
                package.safe_zip_entries(archive)

    def test_symlink_rejected(self):
        entry = zipfile.ZipInfo("link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(zip_bytes([(entry, b"../outside")])) as archive, self.assertRaises(package.PackageError):
            package.safe_zip_entries(archive)


class ActualIPATests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if IPA is None:
            raise unittest.SkipTest("Pass --ipa for actual version-locked IPA integration tests")
        cls.workspace = Path(__file__).resolve().parent
        cls.directory = cls.workspace / ("package-tests-" + uuid.uuid4().hex)
        cls.directory.mkdir()
        cls.original = IPA.resolve(strict=True)
        cls.dylib = cls.directory / "FMExtension.dylib"
        cls.dylib.write_bytes(fixture())
        cls.bootstrap = cls.directory / "LXBootstrap.js"
        cls.bootstrap.write_text("/* Test-only structural fixture, not a real extension. */\n", encoding="utf-8")
        cls.output = cls.directory / "fixture.unsigned.needs-resigning.ipa"
        cls.report = package.package_ipa(cls.original, cls.dylib, cls.bootstrap, cls.output)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "directory"):
            resolved = cls.directory.resolve()
            if resolved.parent != cls.workspace or not resolved.name.startswith("package-tests-"):
                raise RuntimeError("Refusing cleanup outside test workspace")
            shutil.rmtree(resolved)

    def test_actual_host_injection_preserves_segment_offsets(self):
        with zipfile.ZipFile(self.original) as before, zipfile.ZipFile(self.output) as after:
            a = before.read(package.MAIN)
            b = after.read(package.MAIN)
            self.assertEqual(package.parse_macho(a).segments, package.parse_macho(b).segments)
            self.assertEqual(len(a), len(b))
            self.assertEqual(a[artwork.OFFSET:artwork.OFFSET + 4], b[artwork.OFFSET:artwork.OFFSET + 4])
            self.assertEqual(a[0x4000:6147184], b[0x4000:6147184])
            self.assertEqual(b[6147184:], bytes(len(b) - 6147184))

    def test_only_intended_zip_entries_change_and_bundle_settings_unchanged(self):
        with zipfile.ZipFile(self.original) as before, zipfile.ZipFile(self.output) as after:
            removed = {n for n in before.namelist() if package.is_obsolete_app_signature(n)}
            self.assertEqual(set(after.namelist()), set(before.namelist()) - removed | {package.DYLIB_ENTRY, package.BOOTSTRAP_ENTRY})
            for name in before.namelist():
                if name != package.MAIN and name not in removed:
                    self.assertEqual(before.read(name), after.read(name), name)
            self.assertNotIn(package.APP + "embedded.mobileprovision", after.namelist())
            for name in [package.MAIN, package.DYLIB_ENTRY]:
                self.assertFalse(any(c.kind == 0x1D for c in package.parse_macho(after.read(name)).commands))
            self.assertEqual(after.read(package.BOOTSTRAP_ENTRY), self.bootstrap.read_bytes())

    def test_original_sha_and_default_artwork_setting(self):
        self.assertEqual(artwork.file_digest(self.original), artwork.IPA_SHA256)
        self.assertFalse(self.report["artwork_1600_enabled"])
        self.assertFalse(self.report["bundle_id_changed"])
        self.assertFalse(self.report["entitlements_added"])

    def test_artwork_is_explicitly_opt_in(self):
        output = self.directory / "artwork.unsigned.needs-resigning.ipa"
        report = package.package_ipa(self.original, self.dylib, self.bootstrap, output, artwork_1600=True)
        self.assertTrue(report["artwork_1600_enabled"])
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read(package.MAIN)[artwork.OFFSET:artwork.OFFSET + 4], artwork.NEW_INSTRUCTION)

    def test_cannot_overwrite_original_or_existing_output(self):
        for target in [self.original, self.output]:
            with self.assertRaises(artwork.PatchError):
                package.package_ipa(self.original, self.dylib, self.bootstrap, target)
        self.assertEqual(artwork.file_digest(self.original), artwork.IPA_SHA256)

    def test_repacking_modified_ipa_is_rejected(self):
        with self.assertRaisesRegex(package.PackageError, "SHA256 mismatch"):
            package.package_ipa(self.output, self.dylib, self.bootstrap, self.directory / "twice.unsigned.needs-resigning.ipa")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--ipa", type=Path)
    args, remaining = parser.parse_known_args()
    IPA = args.ipa
    unittest.main(argv=[sys.argv[0], *remaining])
