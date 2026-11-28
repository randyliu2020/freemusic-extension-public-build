"""Version-locked FreeMusic 4.2.9 navigation changes.

Apply after load-command/signature rewriting, using the separately verified
original executable as provenance. No Swift functions are called from foreign
code. The original initializer only changes its Tab value from home(0) to
library(2); two existing optional-view branches select their existing nil path.
The existing native Downloads row becomes the first child of the Library List.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct
import download_order_patch

ORIGINAL_SHA256 = "59bb22eb6fb7a62bf574e8b42c9a16f1b3774368bda484a41ce9bea4b8af992f"
ORIGINAL_SIZE = 6160080
UUID = bytes.fromhex("212e31089a0c3309bedc7e996e8199d1")
STUB_OFFSET = 0x3F00
STUB_END = 0x3F0C
CONTEXTS = {
    0x22038: bytes.fromhex("e00315aaf0fbff97160840f9739b0f94d60000b4e8031baae00315aa0e0100941900805202000014"),
    0x22098: bytes.fromhex("e00315aaf3fbff97190840f95b9b0f94b90000b4e8031caae00315aa2101009416008052402900d0"),
    0x1941ec: bytes.fromhex("ebd20994f30300aa081e00b0086947f9ff3f0039211c009021202e910800088be03f009171c20994"),
}

class NavigationPatchError(ValueError):
    pass

def branch(source: int, target: int) -> bytes:
    delta = target-source
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise NavigationPatchError("Unaligned or out-of-range ARM64 branch")
    return struct.pack("<I", 0x14000000 | ((delta // 4) & 0x3ffffff))

PATCHES = {
    0x22048: (bytes.fromhex("d60000b4"), branch(0x22048, 0x22060), "profile_recent_optional_nil"),
    0x220A8: (bytes.fromhex("b90000b4"), branch(0x220A8, 0x220BC), "profile_cover_grid_optional_nil"),
    0x1941fc: (bytes.fromhex("ff3f0039"), branch(0x1941fc, STUB_OFFSET), "initial_tab_library"),
    STUB_OFFSET: (bytes(12), bytes.fromhex("49008052e93f0039") + branch(STUB_OFFSET+8, 0x194200), "initial_tab_inline_trampoline"),
}

def verify_macho(data: bytes) -> None:
    if len(data) != ORIGINAL_SIZE:
        raise NavigationPatchError("Executable size differs from the verified build")
    magic, cpu, _, filetype, count, size = struct.unpack_from("<6I", data)
    if (magic, cpu, filetype) != (0xfeedfacf, 0x100000c, 2):
        raise NavigationPatchError("Expected the verified ARM64 Mach-O executable")
    end = 32+size
    if count > 1024 or end > STUB_OFFSET:
        raise NavigationPatchError("Load commands overlap the reserved navigation trampoline")
    offset = 32
    found_uuid = False
    executable_header = False
    for _ in range(count):
        if offset+8 > end:
            raise NavigationPatchError("Truncated load command")
        kind, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset+length > end:
            raise NavigationPatchError("Invalid load command range")
        if kind == 0x1b:
            found_uuid = length == 24 and data[offset+8:offset+24] == UUID
        if kind == 0x19 and length >= 72:
            name = data[offset+8:offset+24].rstrip(b"\0")
            vmaddr, vmsize, fileoff, filesize, _, initial = struct.unpack_from("<QQQQII", data, offset+24)
            if name == b"__TEXT":
                executable_header = fileoff == 0 and vmaddr == 0x100000000 and filesize >= STUB_END and bool(initial & 4)
        offset += length
    if offset != end or not found_uuid or not executable_header:
        raise NavigationPatchError("UUID or executable header mapping does not match")

def patch_binary(current: bytes, original: bytes) -> tuple[bytes, dict]:
    if hashlib.sha256(original).hexdigest() != ORIGINAL_SHA256:
        raise NavigationPatchError("Original executable fingerprint mismatch")
    verify_macho(original)
    verify_macho(current)
    for offset, expected in CONTEXTS.items():
        if current[offset:offset+len(expected)] != expected:
            raise NavigationPatchError(f"Navigation instruction context changed at {offset:#x}")
    result = bytearray(current)
    changes = []
    plan = [(offset, *entry) for offset, entry in PATCHES.items()]
    plan.extend(download_order_patch.changes(current, original))
    for offset, old, new, purpose in plan:
        if current[offset:offset+len(old)] != old:
            raise NavigationPatchError(f"Navigation patch location is occupied at {offset:#x}")
        result[offset:offset+len(new)] = new
        changes.append({"offset":offset,"before":old.hex(),"after":new.hex(),"purpose":purpose})
    return bytes(result), {
        "original_sha256":ORIGINAL_SHA256,
        "input_sha256":hashlib.sha256(current).hexdigest(),
        "output_sha256":hashlib.sha256(result).hexdigest(),
        "uuid":UUID.hex(), "file_size_unchanged":True,
        "initial_tab":"library", "profile_sections":"native optional nil branches",
        "reserved_header_range":[STUB_OFFSET,STUB_END], "changes":changes,
        "startup_destination":"library_root", "favorites_navigation":"manual",
        "library_first_row":"native_local_downloads", "library_second_row":"native_recent_plays",
        "download_tracks_order":"display_only_han_pinyin_then_latin_then_other",
        "discover_visibility":"handled by public UITab placement filters, model order retained",
    }

def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original-bin",required=True,type=Path)
    parser.add_argument("--input-bin",required=True,type=Path)
    parser.add_argument("--output-bin",required=True,type=Path)
    args=parser.parse_args()
    try:
        original=args.original_bin.resolve(strict=True); source=args.input_bin.resolve(strict=True); output=args.output_bin.resolve()
        if output in (original,source) or output.exists():
            raise NavigationPatchError("Output must be a new file, separate from original and input")
        data,report=patch_binary(source.read_bytes(),original.read_bytes())
        output.write_bytes(data)
        print(json.dumps(report,indent=2))
        return 0
    except (OSError,ValueError,struct.error) as error:
        print(f"FAILED: {error}")
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
