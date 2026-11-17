"""Inject a compiled iOS arm64 extension into the SHA256-locked original IPA.

Pure Python; no archive extraction or target-code execution. Original files are
never overwritten. Output is unsigned and MUST be fully re-signed with the
user's own valid signing inputs. No bundle ID or entitlements are added/changed.
Mach-O layout follows Apple's public mach-o/loader.h. Segment offsets and sizes
stay identical; obsolete signature data is zeroed instead of relocating data.
"""
from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import stat
import struct
import sys
import unicodedata
import zipfile

import artwork_patch

APP = "Payload/FreeMusic.app/"
MAIN = artwork_patch.BINARY_ENTRY
DYLIB_NAME = "@executable_path/Frameworks/FMExtension.dylib"
DYLIB_CURRENT_VERSION = 0x10000
DYLIB_COMPATIBILITY_VERSION = 0x10000
DYLIB_ENTRY = APP + "Frameworks/FMExtension.dylib"
BOOTSTRAP_ENTRY = APP + "LXBootstrap.js"
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
DYLIB_COMMANDS = {0xC, 0x18 | 0x80000000, 0x1F | 0x80000000, 0x23 | 0x80000000, 0x20}
LINKEDIT_DATA_COMMANDS = {0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034, 0x36, 0x37, 0x38}


class PackageError(ValueError):
    pass


@dataclass(frozen=True)
class Command:
    kind: int
    offset: int
    raw: bytes


@dataclass(frozen=True)
class MachO:
    filetype: int
    command_end: int
    first_data: int
    commands: tuple[Command, ...]
    segments: tuple[tuple[str, int, int, int, int], ...]
    ranges: tuple[tuple[str, int, int], ...]
    platform: int
    minos: int


def checked_range(data: bytes, offset: int, length: int, name: str) -> None:
    if offset < 0 or length < 0 or offset + length > len(data):
        raise PackageError(f"Out-of-bounds {name} range")


def command_string(command: Command) -> str:
    if len(command.raw) < 24:
        raise PackageError("Truncated dylib command")
    offset, = struct.unpack_from("<I", command.raw, 8)
    if not 24 <= offset < len(command.raw):
        raise PackageError("Invalid dylib name offset")
    end = command.raw.find(b"\0", offset)
    if end < 0:
        raise PackageError("Unterminated dylib name")
    try:
        return command.raw[offset:end].decode("utf-8")
    except UnicodeDecodeError as error:
        raise PackageError("Dylib name is not UTF-8") from error


def parse_macho(data: bytes, expected_type: int | None = None) -> MachO:
    if len(data) < 32:
        raise PackageError("Truncated Mach-O header")
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or subtype & 0xFFFFFF != 0:
        raise PackageError("Expected thin little-endian arm64 Mach-O (not fat, arm64e, simulator or another CPU)")
    if expected_type is not None and filetype != expected_type:
        raise PackageError(f"Wrong Mach-O file type: expected {expected_type}, got {filetype}")
    end = 32 + sizeofcmds
    if end > len(data) or sizeofcmds % 8 or ncmds > sizeofcmds // 8:
        raise PackageError("Invalid load-command header")
    commands, segments, ranges, section_offsets = [], [], [], []
    cursor = 32
    platform = minos = 0
    for _ in range(ncmds):
        if cursor + 8 > end:
            raise PackageError("Load commands exceed declared size")
        kind, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or size % 8 or cursor + size > end:
            raise PackageError("Malformed load command")
        raw = data[cursor:cursor + size]
        command = Command(kind, cursor, raw)
        commands.append(command)
        if kind == LC_SEGMENT_64:
            if size < 72:
                raise PackageError("Truncated segment command")
            name = raw[8:24].split(b"\0")[0].decode("ascii")
            va, vmsize, fileoff, filesize = struct.unpack_from("<4Q", raw, 24)
            checked_range(data, fileoff, filesize, name)
            nsects, = struct.unpack_from("<I", raw, 64)
            if size != 72 + nsects * 80:
                raise PackageError("Invalid section command size")
            segments.append((name, va, vmsize, fileoff, filesize))
            for index in range(nsects):
                pos = 72 + index * 80
                section_size, = struct.unpack_from("<Q", raw, pos + 40)
                section_off, = struct.unpack_from("<I", raw, pos + 48)
                flags, = struct.unpack_from("<I", raw, pos + 64)
                if section_size and flags & 0xFF not in {1, 0xC, 0x12}:
                    checked_range(data, section_off, section_size, "section")
                    if section_off < fileoff or section_off + section_size > fileoff + filesize:
                        raise PackageError("File-backed section is outside its segment")
                    section_offsets.append(section_off)
        elif kind in {0x21, 0x2C}:
            if size < 20:
                raise PackageError("Truncated encryption command")
            cryptoff, cryptsize, cryptid = struct.unpack_from("<3I", raw, 8)
            checked_range(data, cryptoff, cryptsize, "encryption")
            if cryptid:
                raise PackageError("Encrypted Mach-O is unsupported; decryption is not performed")
        elif kind == 0x32:
            if size < 24:
                raise PackageError("Truncated build-version command")
            platform, minos = struct.unpack_from("<2I", raw, 8)
        elif kind == 0x25 and not platform:
            if size != 16:
                raise PackageError("Invalid iOS minimum-version command")
            platform = 2
            minos, = struct.unpack_from("<I", raw, 8)
        if kind in LINKEDIT_DATA_COMMANDS:
            if size != 16:
                raise PackageError("Invalid linkedit-data command")
            off, length = struct.unpack_from("<2I", raw, 8)
            checked_range(data, off, length, "linkedit data")
            if length:
                ranges.append(("signature" if kind == LC_CODE_SIGNATURE else f"command_{kind:x}", off, length))
        elif kind == 0x2:
            if size != 24:
                raise PackageError("Invalid symbol table command")
            symoff, count, stroff, strlen = struct.unpack_from("<4I", raw, 8)
            ranges.extend((("symbols", symoff, count * 16), ("strings", stroff, strlen)))
        elif kind == 0xB:
            if size != 80:
                raise PackageError("Invalid dynamic symbol table command")
            fields = struct.unpack("<20I", raw)
            for index, width in [(8, 8), (10, 56), (12, 4), (14, 4), (16, 8), (18, 8)]:
                ranges.append((f"dysymtab_{index}", fields[index], fields[index + 1] * width))
        elif kind in {0x22, 0x80000022}:
            if size != 48:
                raise PackageError("Invalid dyld-info command")
            fields = struct.unpack("<12I", raw)
            for index in range(2, 12, 2):
                ranges.append((f"dyld_{index}", fields[index], fields[index + 1]))
        if kind in DYLIB_COMMANDS | {LC_ID_DYLIB}:
            command_string(command)
        cursor += size
    if cursor != end:
        raise PackageError("Load-command count and size disagree")
    if platform != 2:
        raise PackageError("Expected an iOS-device binary, not macOS or iOS Simulator")
    if not section_offsets:
        raise PackageError("No file-backed sections: cannot prove safe header padding")
    first_data = min(section_offsets + [off for _, off, length in ranges if length])
    if first_data < end:
        raise PackageError("File-backed data overlaps load commands")
    for name, off, length in ranges:
        checked_range(data, off, length, name)
    return MachO(filetype, end, first_data, tuple(commands), tuple(segments), tuple(ranges), platform, minos)


def dylib_load_command(name: str = DYLIB_NAME) -> bytes:
    encoded = name.encode("utf-8") + b"\0"
    size = (24 + len(encoded) + 7) & ~7
    return struct.pack("<6I", LC_LOAD_DYLIB, size, 24, 0, DYLIB_CURRENT_VERSION, DYLIB_COMPATIBILITY_VERSION) + encoded + b"\0" * (size - 24 - len(encoded))


def validate_extension_dylib(info: MachO) -> dict:
    identities = [command for command in info.commands if command.kind == LC_ID_DYLIB]
    if len(identities) != 1 or command_string(identities[0]) != DYLIB_NAME:
        raise PackageError(f"Build dylib with install_name {DYLIB_NAME!r}")
    current, compatible = struct.unpack_from("<II", identities[0].raw, 16)
    if current < compatible:
        raise PackageError("Dylib current_version is lower than its compatibility_version")
    if current < DYLIB_COMPATIBILITY_VERSION:
        raise PackageError("Dylib current_version is lower than the injected load command requires (1.0.0); rebuild with explicit dylib versions")
    return {"current_version": current, "compatibility_version": compatible,
            "load_required_version": DYLIB_COMPATIBILITY_VERSION}


def rewrite_macho(data: bytes, *, inject: bool, expected_type: int) -> tuple[bytes, dict]:
    before = parse_macho(data, expected_type)
    existing = [command_string(c) for c in before.commands if c.kind in DYLIB_COMMANDS]
    if inject and DYLIB_NAME in existing:
        raise PackageError("FMExtension LC_LOAD_DYLIB is already present")
    signatures = [c for c in before.commands if c.kind == LC_CODE_SIGNATURE]
    if len(signatures) > 1:
        raise PackageError("Multiple code-signature commands are unsupported")
    sign_ranges = [(off, length) for kind, off, length in before.ranges if kind == "signature"]
    for off, length in sign_ranges:
        if not any(name == "__LINKEDIT" and start <= off and off + length <= start + size
                   for name, _, _, start, size in before.segments):
            raise PackageError("Code-signature blob is outside __LINKEDIT")
        for kind, other, size in before.ranges:
            if kind != "signature" and size and max(off, other) < min(off + length, other + size):
                raise PackageError("Code-signature blob overlaps live linkedit data")
    new_commands = [c.raw for c in before.commands if c.kind != LC_CODE_SIGNATURE]
    if inject:
        new_commands.append(dylib_load_command())
    commands_blob = b"".join(new_commands)
    new_end = 32 + len(commands_blob)
    if new_end > before.first_data:
        raise PackageError(f"Insufficient header padding: need {new_end - before.command_end} extra bytes; available {before.first_data - before.command_end}. Segment relocation is deliberately unsupported.")
    if any(data[before.command_end:before.first_data]):
        raise PackageError("Header padding is not all zero; refusing to overwrite possible live data")
    result = bytearray(data)
    rewrite_end = max(new_end, before.command_end)
    result[32:rewrite_end] = commands_blob + b"\0" * (rewrite_end - new_end)
    struct.pack_into("<II", result, 16, len(new_commands), len(commands_blob))
    for off, length in sign_ranges:
        result[off:off + length] = b"\0" * length
    result = bytes(result)
    after = parse_macho(result, expected_type)
    if after.segments != before.segments or len(result) != len(data):
        raise PackageError("Unexpected segment relocation or binary-size change")
    if any(c.kind == LC_CODE_SIGNATURE for c in after.commands):
        raise PackageError("Code-signature command removal failed")
    expected_names = existing + ([DYLIB_NAME] if inject else [])
    if [command_string(c) for c in after.commands if c.kind in DYLIB_COMMANDS] != expected_names:
        raise PackageError("Unexpected dylib dependency change")
    return result, {"old_header_end": before.command_end, "new_header_end": after.command_end,
        "first_file_data": before.first_data, "signature_bytes_zeroed": sum(n for _, n in sign_ranges),
        "segments_unchanged": True, "file_size_unchanged": True,
        "lc_load_dylib_added": DYLIB_NAME if inject else None}


def safe_zip_entries(archive: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    entries = archive.infolist()
    seen = set()
    files = set()
    for info in entries:
        name = info.filename
        # ZipInfo normalizes backslashes on Windows and truncates NULs. Inspect
        # the original decoded archive name too, before trusting that cleanup.
        raw_name = info.orig_filename
        parts = name.rstrip("/").split("/")
        if (not name or name.startswith("/") or "\\" in raw_name or ":" in raw_name or "\0" in raw_name
                or any(part in {"", ".", ".."} for part in parts)):
            raise PackageError(f"Unsafe ZIP path: {name!r}")
        normalized = unicodedata.normalize("NFC", name.rstrip("/")).casefold()
        if normalized in seen:
            raise PackageError(f"Duplicate/colliding ZIP path: {name!r}")
        seen.add(normalized)
        if stat.S_ISLNK(info.external_attr >> 16):
            raise PackageError(f"Symlink ZIP entry is unsupported: {name!r}")
        if not info.is_dir():
            files.add(normalized)
        if info.flag_bits & 1:
            raise PackageError("Encrypted ZIP entries are unsupported")
    for name in seen:
        parts = name.split("/")
        if any("/".join(parts[:index]) in files for index in range(1, len(parts))):
            raise PackageError("ZIP path descends through a file")
    return entries


def is_obsolete_app_signature(name: str) -> bool:
    return (name.startswith(APP + "_CodeSignature/") or name == APP + "_CodeSignature"
            or name in {APP + "CodeResources", APP + "embedded.mobileprovision"})


def new_entry(name: str, *, executable: bool = False) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
    return info


def package_ipa(original: Path, dylib: Path, bootstrap: Path, output: Path, *, artwork_1600: bool = False, v3_changes: bool = False, player_left_swipe: bool = False, playback_cache: bool = False) -> dict:
    if player_left_swipe and not v3_changes:
        raise PackageError("Player swipe requires the cumulative --v3-changes baseline")
    if playback_cache and not v3_changes:
        raise PackageError("Playback cache isolation requires the cumulative --v3-changes baseline")
    original, output = artwork_patch.check_paths(original, output)
    if not output.name.endswith(".unsigned.needs-resigning.ipa"):
        raise PackageError("Output name must end with .unsigned.needs-resigning.ipa")
    if artwork_patch.file_digest(original) != artwork_patch.IPA_SHA256:
        raise PackageError("Original IPA SHA256 mismatch; only the supplied untouched version is supported")
    dylib = dylib.resolve(strict=True)
    bootstrap = bootstrap.resolve(strict=True)
    if output.resolve() in {dylib, bootstrap}:
        raise PackageError("Output cannot overwrite extension inputs")
    library = dylib.read_bytes()
    libinfo = parse_macho(library, 6)
    libversions = validate_extension_dylib(libinfo)
    script = bootstrap.read_bytes()
    if not script or len(script) > 8 * 1024 * 1024:
        raise PackageError("Bootstrap must be a nonempty JavaScript text file smaller than 8 MiB")
    try:
        script.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise PackageError("Bootstrap is not valid UTF-8 text") from error
    clean_library, libreport = rewrite_macho(library, inject=False, expected_type=6)
    removed, expected = [], {}
    with zipfile.ZipFile(original) as archive:
        entries = safe_zip_entries(archive)
        names = {info.filename for info in entries}
        if MAIN not in names or DYLIB_ENTRY in names or BOOTSTRAP_ENTRY in names:
            raise PackageError("Original app executable missing or extension resources already exist")
        executable = archive.read(MAIN)
        if artwork_patch.digest(executable) != artwork_patch.BINARY_SHA256:
            raise PackageError("Original main executable SHA256 mismatch")
        maininfo = parse_macho(executable, 2)
        if libinfo.minos > maininfo.minos:
            raise PackageError("Dylib minimum iOS exceeds the host executable minimum; rebuild with a compatible deployment target")
        original_executable = executable
        artreport = None
        v3report = None
        if artwork_1600:
            executable, artreport = artwork_patch.patch_binary(executable)
        executable, mainreport = rewrite_macho(executable, inject=True, expected_type=2)
        if v3_changes:
            import navigation_patch
            import interaction_patch
            try:
                lyric_plan = interaction_patch.patch_plan(original_executable)
                executable, navigation_report = navigation_patch.patch_binary(executable, original_executable)
                executable = interaction_patch.apply_verified_plan(executable, lyric_plan)
                swipe_plan = []
                if player_left_swipe:
                    import player_swipe_patch
                    swipe_plan = player_swipe_patch.patch_plan(original_executable)
                    executable = interaction_patch.apply_verified_plan(executable, swipe_plan)
                cache_plan = []
                if playback_cache:
                    import playback_cache_patch
                    cache_plan = playback_cache_patch.patch_plan(original_executable)
                    executable = interaction_patch.apply_verified_plan(executable, cache_plan)
                v3report = {"navigation": navigation_report,
                    "lyric_changes": [{"offset": hex(change.offset), "length": len(change.after), "reason": change.reason} for change in lyric_plan],
                    "player_swipe_changes": [{"offset": hex(change.offset), "length": len(change.after), "reason": change.reason} for change in swipe_plan],
                    "playback_cache_changes": [{"offset": hex(change.offset), "length": len(change.after), "reason": change.reason} for change in cache_plan],
                    "original_main_sha256": artwork_patch.digest(original_executable),
                    "combined_main_sha256": artwork_patch.digest(executable),
                    "device_execution_validated": False}
            except ValueError as error:
                raise PackageError(f"Verified v3 changes could not be applied: {error}") from error
        created = False
        try:
            with output.open("xb") as handle:
                created = True
                with zipfile.ZipFile(handle, "w", allowZip64=True) as result:
                    result.comment = archive.comment
                    for info in entries:
                        if is_obsolete_app_signature(info.filename):
                            removed.append(info.filename)
                            continue
                        data = executable if info.filename == MAIN else archive.read(info)
                        expected[info.filename] = artwork_patch.digest(data)
                        result.writestr(copy.copy(info), data)
                    result.writestr(new_entry(DYLIB_ENTRY, executable=True), clean_library)
                    result.writestr(new_entry(BOOTSTRAP_ENTRY), script)
                    expected[DYLIB_ENTRY] = artwork_patch.digest(clean_library)
                    expected[BOOTSTRAP_ENTRY] = artwork_patch.digest(script)
            with zipfile.ZipFile(output) as result:
                if {info.filename for info in safe_zip_entries(result)} != set(expected):
                    raise PackageError("Unexpected output archive entry set")
                for name, checksum in expected.items():
                    if artwork_patch.digest(result.read(name)) != checksum:
                        raise PackageError(f"Output archive verification failed: {name}")
            if artwork_patch.file_digest(original) != artwork_patch.IPA_SHA256:
                raise PackageError("Original IPA changed during packaging")
        except Exception:
            if created:
                output.unlink(missing_ok=True)
            raise
    return {"status": "UNSIGNED_REQUIRES_FULL_RESIGNING_AND_DEVICE_TEST", "output": str(output),
        "original_sha256": artwork_patch.IPA_SHA256, "output_sha256": artwork_patch.file_digest(output),
        "main": mainreport, "dylib": libreport, "dylib_versions": libversions, "removed_app_signing_files": removed,
        "bootstrap_sha256": artwork_patch.digest(script), "dylib_sha256": artwork_patch.digest(clean_library),
        "artwork_1600_enabled": artwork_1600, "artwork_report": artreport,
        "v3_changes_enabled": v3_changes, "v3_report": v3report,
        "player_left_swipe_enabled": player_left_swipe,
        "playback_cache_enabled": playback_cache,
        "bundle_id_changed": False, "entitlements_added": False, "original_preserved": True,
        "signing_note": "Main app and added dylib have no LC_CODE_SIGNATURE. Existing nested framework signatures are unchanged archive content, not authority to reuse. Fully sign nested code and main app with valid user-provided signing inputs; old app profile was removed.",
        "validation_scope": "Structural packaging checks only; extension behavior and iPhone installation/playback are not verified here."}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("--dylib", type=Path, required=True)
    parser.add_argument("--bootstrap", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artwork-1600", action="store_true", help="Optional experimental artwork decode limit; default off")
    parser.add_argument("--v3-changes", action="store_true", help="Apply verified original-build lyric and navigation changes")
    parser.add_argument("--player-left-swipe", action="store_true", help="Add left-swipe dismissal to the original player top bars; preserve downward dismissal")
    parser.add_argument("--playback-cache", action="store_true", help="Isolate automatic playback cache after JS source transitions; preserve downloaded files")
    args = parser.parse_args()
    try:
        report = package_ipa(args.original, args.dylib, args.bootstrap, args.output, artwork_1600=args.artwork_1600, v3_changes=args.v3_changes, player_left_swipe=args.player_left_swipe, playback_cache=args.playback_cache)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except (OSError, PackageError, artwork_patch.PatchError, zipfile.BadZipFile, struct.error, UnicodeError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
