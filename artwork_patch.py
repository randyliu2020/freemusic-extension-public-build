"""Version-locked FreeMusic artwork experiment; never edits the original IPA.

The single change permits 1600-pixel decoding for lock-screen artwork. Known
provider URL size tables remain unchanged. Their existing 1000/800/700/480 caps
mean this does not promise better images from those providers. Output needs a
new, valid signature. This tool neither signs nor applies old signing rights.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import struct
import sys
import zipfile

IPA_SHA256 = "4f6d3ba77dea7b04feb9ff3852416cbf80c29fc24df1cfe82a93d6654a61cba1"
BINARY_SHA256 = "59bb22eb6fb7a62bf574e8b42c9a16f1b3774368bda484a41ce9bea4b8af992f"
BINARY_ENTRY = "Payload/FreeMusic.app/FreeMusic"
BINARY_SIZE = 6160080
OFFSET = 0x631C8
OLD_SIZE = 1000
NEW_SIZE = 1600
OLD_INSTRUCTION = bytes.fromhex("057d8052")
NEW_INSTRUCTION = bytes.fromhex("05c88052")
CONTEXT_OFFSET = 0x631B8
ORIGINAL_CONTEXT = bytes.fromhex(
    "f60300aae00308aae10313aae30314aa057d8052e6cf40a9fd7b42a9bdfb4392ffc30091"
)

# Relative virtual addresses resolved through LC_SEGMENT_64 VA-to-file mapping. Each array
# belongs to the original URL resizing code, not to the local decoding cap.
PROVIDER_TABLES = {
    "music.126.net": (0x551728, [150, 300, 500, 800, 1000]),
    "qq.com": (0x551780, [150, 300, 500, 800]),
    "gtimg.cn": (0x5517C8, [150, 300, 500, 800]),
    "kuwo.cn": (0x551810, [120, 300, 500, 700]),
    "kugou.com": (0x551858, [150, 240, 400, 480]),
}


class PatchError(ValueError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def decode_movz_w5(instruction: bytes) -> int:
    """Decode exactly ARM64 MOVZ W5,#imm16,LSL#0 (MOV immediate alias)."""
    if len(instruction) != 4:
        raise PatchError("An ARM64 instruction must contain four bytes")
    word, = struct.unpack("<I", instruction)
    if word & ~(0xFFFF << 5) != 0x52800005:
        raise PatchError("Instruction is not MOVZ W5,#imm16,LSL#0")
    return (word >> 5) & 0xFFFF


def provider_size(requested: int, supported: list[int]) -> int:
    """Model the unchanged ascending-table selection at 0xF027C-0xF02A4."""
    return next((size for size in supported if size >= requested), supported[-1])


def macho_file_offset(data: bytes, virtual_address: int) -> int:
    magic, cpu, _, _, ncmds, sizeofcmds = struct.unpack_from("<6I", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise PatchError("Expected a thin arm64 Mach-O")
    cursor = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or cursor + size > 32 + sizeofcmds:
            raise PatchError("Invalid Mach-O load command")
        if cmd == 0x19:
            va, _, offset, length = struct.unpack_from("<4Q", data, cursor + 24)
            if va <= virtual_address < va + length:
                return offset + virtual_address - va
        cursor += size
    raise PatchError("Virtual address is not backed by a file segment")


def verify_provider_tables(data: bytes) -> dict:
    result = {}
    for provider, (relative_va, expected) in PROVIDER_TABLES.items():
        offset = macho_file_offset(data, 0x100000000 + relative_va)
        actual = list(struct.unpack_from(f"<{len(expected)}Q", data, offset))
        if actual != expected:
            raise PatchError(f"Unexpected provider artwork sizes: {provider}")
        old = provider_size(OLD_SIZE, actual)
        new = provider_size(NEW_SIZE, actual)
        if old != new:
            raise PatchError(f"Patch would change an upstream URL size: {provider}")
        result[provider] = {"supported": actual, "before": old, "after": new}
    return result


def patch_binary(original: bytes) -> tuple[bytes, dict]:
    if len(original) != BINARY_SIZE or digest(original) != BINARY_SHA256:
        raise PatchError("Unsupported or already modified executable; SHA256 mismatch")
    if original[CONTEXT_OFFSET:CONTEXT_OFFSET + len(ORIGINAL_CONTEXT)] != ORIGINAL_CONTEXT:
        raise PatchError("Unexpected surrounding instruction sequence")
    if original[OFFSET:OFFSET + 4] != OLD_INSTRUCTION:
        raise PatchError("Original instruction mismatch")
    if decode_movz_w5(OLD_INSTRUCTION) != OLD_SIZE:
        raise PatchError("Original ARM64 immediate verification failed")
    if decode_movz_w5(NEW_INSTRUCTION) != NEW_SIZE:
        raise PatchError("Replacement ARM64 immediate verification failed")
    providers = verify_provider_tables(original)
    patched = original[:OFFSET] + NEW_INSTRUCTION + original[OFFSET + 4:]
    if patched[:OFFSET] != original[:OFFSET] or patched[OFFSET + 4:] != original[OFFSET + 4:]:
        raise PatchError("Unexpected executable changes")
    if decode_movz_w5(patched[OFFSET:OFFSET + 4]) != NEW_SIZE:
        raise PatchError("Patched ARM64 instruction verification failed")
    if verify_provider_tables(patched) != providers:
        raise PatchError("Provider tables changed")
    return patched, {
        "binary_entry": BINARY_ENTRY,
        "input_binary_sha256": BINARY_SHA256,
        "output_binary_sha256": digest(patched),
        "instruction_offset": hex(OFFSET),
        "before": {"hex": OLD_INSTRUCTION.hex(), "assembly": "mov w5, #1000"},
        "after": {"hex": NEW_INSTRUCTION.hex(), "assembly": "mov w5, #1600"},
        "provider_url_sizes_unchanged": providers,
    }


def check_paths(original: Path, output: Path) -> tuple[Path, Path]:
    original = original.resolve(strict=True)
    output = output.absolute()
    if output.resolve() == original or output.exists() or output.is_symlink():
        raise PatchError("Output must be a new file, distinct from the original")
    if not output.parent.is_dir():
        raise PatchError("Output parent directory must exist")
    return original, output


def verify_archive(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise PatchError("Duplicate ZIP entries are not allowed")
        if BINARY_ENTRY not in names:
            raise PatchError("Expected executable is missing")
        if (bad := archive.testzip()) is not None:
            raise PatchError(f"ZIP integrity check failed: {bad}")
        return names


def verify_only_target_changed(original: Path, output: Path, expected_binary: bytes) -> None:
    with zipfile.ZipFile(original) as before, zipfile.ZipFile(output) as after:
        if before.namelist() != after.namelist():
            raise PatchError("Archive entry list changed")
        for entry in before.namelist():
            expected = expected_binary if entry == BINARY_ENTRY else before.read(entry)
            if after.read(entry) != expected:
                raise PatchError(f"Unexpected archive content change: {entry}")


def patch_ipa(original: Path, output: Path) -> dict:
    original, output = check_paths(original, output)
    if file_digest(original) != IPA_SHA256:
        raise PatchError("Unsupported IPA; the complete original SHA256 must match")
    verify_archive(original)
    with zipfile.ZipFile(original) as source:
        binary, evidence = patch_binary(source.read(BINARY_ENTRY))
        created = False
        try:
            with output.open("xb") as file:
                created = True
                with zipfile.ZipFile(file, "w", allowZip64=True) as destination:
                    destination.comment = source.comment
                    for info in source.infolist():
                        content = binary if info.filename == BINARY_ENTRY else source.read(info)
                        destination.writestr(copy.copy(info), content)
            verify_archive(output)
            verify_only_target_changed(original, output, binary)
            if file_digest(original) != IPA_SHA256:
                raise PatchError("Original IPA changed during patch operation")
        except Exception:
            if created:
                output.unlink(missing_ok=True)
            raise
    return {
        "status": "EXPERIMENTAL_REQUIRES_RESIGNING_AND_DEVICE_TEST",
        "input": str(original), "output": str(output),
        "input_ipa_sha256": IPA_SHA256, "output_ipa_sha256": file_digest(output),
        "signature_note": "Embedded signing records are retained as original archive content but are INVALID after binary modification. This tool performs no signing and grants no entitlements. A signing workflow must discard obsolete signing artifacts and use the user's own valid provisioning/signature.",
        "scope": "Only lock-screen artwork decode request 1000 -> 1600. Known provider URLs and caps are unchanged. No lock-screen app-opening change.",
        "expected_limit": "May retain detail from larger local/original images; cannot improve an already smaller provider image. Worst-case decoded image pixel count rises by 2.56x for this request.",
        "device_validation": "Not performed. Confirm memory/track switching, artwork changes, lock/unlock and background playback on the signed build.",
        **evidence,
    }


def restore_original(original: Path, output: Path) -> dict:
    """Rollback creates a byte-for-byte original copy; it never overwrites files."""
    original, output = check_paths(original, output)
    if file_digest(original) != IPA_SHA256:
        raise PatchError("Rollback source is not the SHA256-verified original IPA")
    created = False
    try:
        with original.open("rb") as source, output.open("xb") as destination:
            created = True
            shutil.copyfileobj(source, destination)
        if file_digest(output) != IPA_SHA256:
            raise PatchError("Rollback copy verification failed")
    except Exception:
        if created:
            output.unlink(missing_ok=True)
        raise
    return {"status": "RESTORED_ORIGINAL_COPY", "output": str(output), "sha256": IPA_SHA256}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["inspect", "patch", "restore"])
    parser.add_argument("original", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "inspect":
            if file_digest(args.original) != IPA_SHA256:
                raise PatchError("Unsupported IPA SHA256")
            verify_archive(args.original)
            with zipfile.ZipFile(args.original) as archive:
                _, report = patch_binary(archive.read(BINARY_ENTRY))
            report["status"] = "MATCHED_ORIGINAL_NO_FILE_CHANGED"
        else:
            if args.output is None:
                raise PatchError("--output is required; original is never edited")
            operation = patch_ipa if args.action == "patch" else restore_original
            report = operation(args.original, args.output)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except (OSError, PatchError, zipfile.BadZipFile) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
