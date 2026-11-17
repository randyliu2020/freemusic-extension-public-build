"""Upgrade validation; --ipa enables local-only tests of the supplied V7 file."""
import argparse
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile

import package_extension as package
from test_package_extension import fixture
import upgrade_v7_ipa as upgrade

IPA = None


def extension_fixture(exports):
    data = bytearray(fixture(signed=False))
    data.extend(bytes(0x1000 - len(data)))
    info = package.parse_macho(data, 6)
    segment = next(c for c in info.commands if c.kind == 0x19 and c.raw[8:18] == b"__LINKEDIT")
    struct.pack_into("<Q", data, segment.offset + 48, 0xB00)
    table = next(c for c in info.commands if c.kind == 2)
    strings = bytearray(b"\0")
    symbols = bytearray()
    for name in exports:
        symbols += struct.pack("<IBBHQ", len(strings), 0x0F, 1, 0, 0x400)
        strings += name.encode() + b"\0"
    struct.pack_into("<4I", data, table.offset + 8, 0x500, len(exports), 0x600, len(strings))
    data[0x500:0x500 + len(symbols)] = symbols
    data[0x600:0x600 + len(strings)] = strings
    return bytes(data)


class ArtifactValidation(unittest.TestCase):
    def setUp(self):
        self.source = Path(__file__).resolve().parent
        self.library = extension_fixture(sorted(upgrade.REQUIRED_EXPORTS))
        self.bootstrap = (self.source / "LXBootstrap.js").read_bytes()
        self.manifest = {
            "artifact_sha256": {"FMExtension.dylib": upgrade.sha(self.library), "LXBootstrap.js": upgrade.sha(self.bootstrap)},
            "source_sha256": {name: upgrade.sha((self.source / name).read_bytes()) for name in upgrade.REQUIRED_SOURCES},
        }

    def test_exported_functions_are_defined_section_symbols(self):
        self.assertEqual(upgrade.exported_symbols(self.library), upgrade.REQUIRED_EXPORTS)

    def test_matching_authored_artifact_provenance_passes(self):
        upgrade.verify_artifact(self.library, self.bootstrap, self.manifest, self.source)

    def test_modified_download_fails_manifest(self):
        with self.assertRaisesRegex(package.PackageError, "manifest mismatch"):
            upgrade.verify_artifact(self.library[:-1] + b"x", self.bootstrap, self.manifest, self.source)

    def test_old_extension_cannot_be_packaged_as_v8(self):
        old = extension_fixture(["_FMXOldVersion"])
        self.manifest["artifact_sha256"]["FMExtension.dylib"] = upgrade.sha(old)
        with self.assertRaisesRegex(package.PackageError, "missing V8 exports"):
            upgrade.verify_artifact(old, self.bootstrap, self.manifest, self.source)

    def test_mismatched_source_cannot_claim_build_provenance(self):
        self.manifest["source_sha256"]["FMPlaybackSequence.m"] = "0" * 64
        with self.assertRaisesRegex(package.PackageError, "differs from the GitHub build"):
            upgrade.verify_artifact(self.library, self.bootstrap, self.manifest, self.source)

    def test_manifest_cannot_read_parent_directory(self):
        self.manifest["source_sha256"]["../outside"] = "0" * 64
        with self.assertRaisesRegex(package.PackageError, "non-local source path"):
            upgrade.verify_artifact(self.library, self.bootstrap, self.manifest, self.source)

    def test_unknown_input_is_rejected_before_output_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "wrong.ipa"
            output = root / "result.unsigned.needs-resigning.ipa"
            source.write_bytes(b"not the user's IPA")
            with self.assertRaisesRegex(package.PackageError, "exact supplied V7"):
                upgrade.upgrade(source, root / "missing.dylib", root / "missing.js", root / "missing.json", output)
            self.assertFalse(output.exists())


class LocalIPATests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if IPA is None:
            raise unittest.SkipTest("Original IPA stays local; pass --ipa for real-input validation")
        with zipfile.ZipFile(IPA) as archive:
            cls.original = archive.read(package.MAIN)
        cls.changed, cls.regions = upgrade.patch_v7_binary(cls.original)

    def test_exact_input_and_v7_dependencies(self):
        self.assertEqual(package.artwork_patch.file_digest(IPA), upgrade.V7_IPA_SHA256)
        before = package.parse_macho(self.original, 2)
        after = package.parse_macho(self.changed, 2)
        self.assertEqual(before, after)

    def test_only_five_declared_regions_change(self):
        allowed = set()
        for row in self.regions:
            start = int(row["offset"], 16)
            allowed.update(range(start, start + row["length"]))
        differences = {i for i, (a, b) in enumerate(zip(self.original, self.changed)) if a != b}
        self.assertTrue(differences)
        self.assertTrue(differences <= allowed)
        self.assertEqual(len(self.regions), 5)

    def test_previous_cache_bridge_and_original_uuid_guards_are_preserved(self):
        self.assertEqual(self.changed[0x57138:0x5713C], self.original[0x57138:0x5713C])
        self.assertEqual(self.changed[0x509000:0x509E40], self.original[0x509000:0x509E40])
        for offset in (0x4A4E0, 0x51050, 0x575D4):
            length, digest = upgrade.sequence.CONTEXTS[offset]
            self.assertEqual(upgrade.sha(self.changed[offset:offset + length]), digest)

    def test_repeated_upgrade_and_unknown_modified_host_are_rejected(self):
        for data in (self.changed, self.original[:-1] + bytes([self.original[-1] ^ 1])):
            with self.assertRaisesRegex(package.PackageError, "exact supplied build"):
                upgrade.patch_v7_binary(data)

    def test_packaged_fixture_preserves_all_other_archive_bytes(self):
        # This temporary library is structural test data, never a deliverable.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = extension_fixture(sorted(upgrade.REQUIRED_EXPORTS))
            dylib = root / "fixture.dylib"
            dylib.write_bytes(library)
            script = Path(__file__).resolve().parent / "LXBootstrap.js"
            manifest = root / "build-manifest.json"
            manifest.write_text(json.dumps({
                "artifact_sha256": {"FMExtension.dylib": upgrade.sha(library), "LXBootstrap.js": upgrade.sha(script.read_bytes())},
                "source_sha256": {name: upgrade.sha((script.parent / name).read_bytes()) for name in upgrade.REQUIRED_SOURCES},
            }))
            output = root / "test-only.unsigned.needs-resigning.ipa"
            report = upgrade.upgrade(IPA, dylib, script, manifest, output)
            with zipfile.ZipFile(IPA) as before, zipfile.ZipFile(output) as after:
                self.assertEqual(set(before.namelist()), set(after.namelist()))
                for name in before.namelist():
                    if name not in {package.MAIN, package.DYLIB_ENTRY, package.BOOTSTRAP_ENTRY}:
                        self.assertEqual(before.read(name), after.read(name), name)
                self.assertEqual(after.read(package.MAIN), self.changed)
            self.assertTrue(report["v7_features_preserved"])
            self.assertFalse(report["physical_device_tested"])
            with self.assertRaises((FileExistsError, ValueError)):
                upgrade.upgrade(IPA, dylib, script, manifest, output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--ipa", type=Path)
    args, rest = parser.parse_known_args()
    IPA = args.ipa
    unittest.main(argv=[sys.argv[0]] + rest)
