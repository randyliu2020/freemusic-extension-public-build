"""Upgrade the exact supplied unsigned V7 IPA with a GitHub-built V8 extension.

The original executable/resources never enter GitHub. This additive upgrade
keeps all V7 patches and installs the two V8 bridges in verified unused space.
No signing, credential changes, DRM changes or original-source reconstruction.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import zipfile

import artwork_selection_patch as cover
import interaction_patch as patch
import package_extension as package
import playback_cache_patch as cache
import playback_sequence_patch as sequence

V7_IPA_SHA256 = "676a45b982009b578535b892a945d23dc1fe8ff67d90dc8f08a903b6bfccfb7c"
V7_MAIN_SHA256 = "86b9fe9cdfab2fa9e659f9a61a73980b87724092cefa6458d3d12badb4bc2dfd"
V7_DYLIB_SHA256 = "3ed4c744dde6a1ded2c453604f8fd98e7e0b4032b2edac040f83f277dd6db829"
V7_BOOTSTRAP_SHA256 = "b6dee30b4a40ff12bd456510d88dc367adfdfe734dd8830bfb5a9bf8704b585f"
REQUIRED_EXPORTS = {
    "_FMPlaybackSequenceNativeSelection", "_FMPlaybackSequenceInstall", "_FMXAC",
    "_FMSettingsMigrate", "_FMXMergeSearchResponsesForKeyword",
    "_OBJC_CLASS_$_FMLXMCLocalStore",
}
REQUIRED_SOURCES = {
    "FMExtension.m", "FMExtensionProtocol.m", "FMPlaybackSequence.m",
    "FMArtworkSelection.m", "FMSettingsMigration.m", "FMLXMCLocalStore.m",
    "FMLXMCLocalProtocol.m", "FMLXMCUI.m", "LXBootstrap.js",
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def exported_symbols(data: bytes) -> set[str]:
    info = package.parse_macho(data, 6)
    table = next((c for c in info.commands if c.kind == 2), None)
    if not table:
        raise package.PackageError("Extension has no inspectable symbol table")
    symoff, count, stroff, strlen = struct.unpack_from("<4I", table.raw, 8)
    strings = data[stroff:stroff + strlen]
    names = set()
    for index in range(count):
        nameoff, kind, section, _, value = struct.unpack_from("<IBBHQ", data, symoff + 16 * index)
        if kind & 0xE0 or kind & 0x0F != 0x0F or not section or not value:
            continue
        end = strings.find(b"\0", nameoff)
        if nameoff >= len(strings) or end < 0:
            raise package.PackageError("Malformed exported symbol name")
        names.add(strings[nameoff:end].decode("utf-8"))
    return names


def verify_artifact(library: bytes, bootstrap: bytes, manifest: dict, source_dir: Path) -> None:
    artifacts = manifest.get("artifact_sha256", {})
    for name, data in (("FMExtension.dylib", library), ("LXBootstrap.js", bootstrap)):
        if artifacts.get(name) != sha(data):
            raise package.PackageError(f"GitHub build manifest mismatch: {name}")
    sources = manifest.get("source_sha256", {})
    if not REQUIRED_SOURCES <= sources.keys():
        raise package.PackageError("Build manifest is missing V8 source provenance")
    for name, digest in sources.items():
        if not isinstance(name, str) or Path(name).name != name:
            raise package.PackageError("Build manifest contains a non-local source path")
        if sha((source_dir / name).read_bytes()) != digest:
            raise package.PackageError(f"Checked-out source differs from the GitHub build: {name}")
    missing = REQUIRED_EXPORTS - exported_symbols(library)
    if missing:
        raise package.PackageError(f"Extension is missing V8 exports: {sorted(missing)}")


def patch_v7_binary(data: bytes) -> tuple[bytes, list[dict]]:
    if len(data) != patch.ORIGINAL_BINARY_SIZE or sha(data) != V7_MAIN_SHA256:
        raise package.PackageError("Unsupported V7 executable; exact supplied build is required")
    before = package.parse_macho(data, 2)
    dependencies = [package.command_string(c) for c in before.commands if c.kind in package.DYLIB_COMMANDS]
    if dependencies.count(package.DYLIB_NAME) != 1 or any(c.kind == package.LC_CODE_SIGNATURE for c in before.commands):
        raise package.PackageError("Expected the unsigned V7 executable with one extension dependency")

    # The V7 cache bridge changes one instruction inside reconcile(). Normalize
    # only a verification copy to the instruction already retained by its
    # authored trampoline, then verify the original full function context.
    normalized = bytearray(data)
    cache_site = 0x57138
    target, digest, _ = cache.SITES[cache_site]
    retained = bytes.fromhex(cache.ENCODED[target])[16:20]
    if data[cache_site:cache_site + 4] != patch.branch(cache_site, target) or sha(retained) != digest:
        raise package.PackageError("Unexpected V7 preload cache bridge")
    normalized[cache_site:cache_site + 4] = retained
    for module in (sequence, cover):
        if any(data[module.CAVE:module.END]):
            raise package.PackageError("V8 bridge space is already occupied")
        for offset, (length, digest) in module.CONTEXTS.items():
            if sha(normalized[offset:offset + length]) != digest:
                raise package.PackageError(f"Original host context mismatch at {offset:#x}")
    changes = [
        patch.Change(sequence.SITE, data[sequence.SITE:sequence.SITE + 4], patch.branch(sequence.SITE, sequence.CAVE), "latest playback selection"),
        patch.Change(sequence.CAVE, bytes(sequence.END - sequence.CAVE), sequence.payload(), "selection and preload bridge"),
        patch.Change(cover.NIL_SITE, data[cover.NIL_SITE:cover.NIL_SITE + 4], patch.branch(cover.NIL_SITE, cover.CAVE), "absent artwork identity"),
        patch.Change(cover.EMPTY_SITE, data[cover.EMPTY_SITE:cover.EMPTY_SITE + 4], patch.branch(cover.EMPTY_SITE, cover.CAVE + 8), "empty artwork identity"),
        patch.Change(cover.CAVE, bytes(cover.END - cover.CAVE), cover.payload(), "artwork ownership bridge"),
    ]
    result = patch.apply_verified_plan(data, changes)
    if package.parse_macho(result, 2) != before or len(result) != len(data):
        raise package.PackageError("Upgrade unexpectedly changed Mach-O layout")
    return result, [{"offset": hex(c.offset), "length": len(c.after), "reason": c.reason} for c in changes]


def upgrade(ipa: Path, dylib: Path, bootstrap: Path, manifest_file: Path, output: Path) -> dict:
    ipa, output = package.artwork_patch.check_paths(ipa, output)
    if not output.name.endswith(".unsigned.needs-resigning.ipa"):
        raise package.PackageError("Output must end with .unsigned.needs-resigning.ipa")
    if output.resolve() in {p.resolve() for p in (dylib, bootstrap, manifest_file)}:
        raise package.PackageError("Output cannot overwrite build inputs")
    if package.artwork_patch.file_digest(ipa) != V7_IPA_SHA256:
        raise package.PackageError("Input IPA is not the exact supplied V7 build")
    library, script = dylib.read_bytes(), bootstrap.read_bytes()
    if not script or len(script) > 8 * 1024 * 1024:
        raise package.PackageError("Invalid bootstrap size")
    script.decode("utf-8-sig")
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    verify_artifact(library, script, manifest, Path(__file__).resolve().parent)
    libinfo = package.parse_macho(library, 6)
    package.validate_extension_dylib(libinfo)
    clean_library, library_report = package.rewrite_macho(library, inject=False, expected_type=6)
    expected, removed = {}, []
    created = False
    try:
        with zipfile.ZipFile(ipa) as source:
            entries = package.safe_zip_entries(source)
            main = source.read(package.MAIN)
            for name, digest in ((package.DYLIB_ENTRY, V7_DYLIB_SHA256), (package.BOOTSTRAP_ENTRY, V7_BOOTSTRAP_SHA256)):
                if sha(source.read(name)) != digest:
                    raise package.PackageError(f"Unexpected V7 resource: {name}")
            upgraded_main, changes = patch_v7_binary(main)
            if libinfo.minos > package.parse_macho(main, 2).minos:
                raise package.PackageError("Extension deployment target exceeds the host")
            replacements = {package.MAIN: upgraded_main, package.DYLIB_ENTRY: clean_library, package.BOOTSTRAP_ENTRY: script}
            with output.open("xb") as handle:
                created = True
                with zipfile.ZipFile(handle, "w", allowZip64=True) as result:
                    result.comment = source.comment
                    for entry in entries:
                        if package.is_obsolete_app_signature(entry.filename):
                            removed.append(entry.filename)
                            continue
                        data = replacements.get(entry.filename)
                        if data is None:
                            data = source.read(entry)
                        expected[entry.filename] = sha(data)
                        result.writestr(copy.copy(entry), data)
        with zipfile.ZipFile(output) as result:
            if {i.filename for i in package.safe_zip_entries(result)} != expected.keys():
                raise package.PackageError("Output archive entries changed unexpectedly")
            for name, digest in expected.items():
                if sha(result.read(name)) != digest:
                    raise package.PackageError(f"Output verification failed: {name}")
        if package.artwork_patch.file_digest(ipa) != V7_IPA_SHA256:
            raise package.PackageError("Input changed during packaging")
    except Exception:
        if created:
            output.unlink(missing_ok=True)
        raise
    return {
        "status": "UNSIGNED_REQUIRES_FULL_RESIGNING_AND_DEVICE_TEST",
        "input_sha256": V7_IPA_SHA256, "output_sha256": package.artwork_patch.file_digest(output),
        "main_sha256": sha(upgraded_main), "dylib_sha256": sha(clean_library), "bootstrap_sha256": sha(script),
        "build_manifest_sha256": sha(manifest_file.read_bytes()), "changes": changes,
        "dylib_report": library_report, "removed_app_signing_files": removed,
        "v7_features_preserved": True, "bundle_identity_and_resources_preserved": True,
        "github_compiled_extension": True, "ipa_packaged_locally": True,
        "physical_device_tested": False, "output": str(output),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--dylib", type=Path, required=True)
    parser.add_argument("--bootstrap", type=Path, required=True)
    parser.add_argument("--build-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(upgrade(args.ipa, args.dylib, args.bootstrap, args.build_manifest, args.output), indent=2))
        return 0
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, struct.error) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
