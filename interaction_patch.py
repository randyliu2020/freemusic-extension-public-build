"""Version-locked local lyric interaction patch. Input is never modified.

The original preview LyricsScroller has a single-tap line handler but nil onSeek.
This patch supplies the exact native immersive seek closure with a native Swift
capture; the preview parent's existing expand gesture becomes double-tap.
No custom audio clock, lyric timestamp, or screen-coordinate interception exists.

patch_plan(original) produces immutable ranges for the parent packager to merge
with other independently verified changes after verifying the original IPA hash.
This module does not sign, upload, or replace an IPA.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import struct

ORIGINAL_BINARY_SHA256 = "03f19d8402580a93ffd772e05512de4a8af533ef9ead51f3c12d334202b17887"
ORIGINAL_BINARY_SIZE = 6288608
BASE = 0x100000000
CAVE = 0x509680
SEEK_SITE = 0x1AB5D4
EXPAND_COUNT_SITE = 0x1A517C
HIT_TESTING_SITE = 0x1AB714
HIT_CAVE = 0x509720
NATIVE_PARENT_METADATA = 0x1C1570
NATIVE_CAPTURE_METADATA = 0x519848
NATIVE_ALLOC = 0x408BD8
NATIVE_INITIALIZE_COPY = 0x1BE40
NATIVE_SEEK_CLOSURE = 0x1C6A70

# Developer verification source. Production packaging needs no assembler.
# At SEEK_SITE: X0=LyricsScroller metadata, X19=preview builder's frame storage,
# [X19+16]=borrowed PlayerView value, X20=initialized LyricsScroller prefix.
# Use the original parent value-witness initializeWithCopy, original capture
# allocation metadata/destructor, and original seek closure. The destination
# assumes ownership of the allocation's +1 reference, just as at 0x1AAA80.
TRAMPOLINE_ASSEMBLY = """
stp x29, x30, [sp, #-96]!
mov x29, sp
stp x19, x20, [sp, #16]
stp x21, x22, [sp, #32]
stp x23, x24, [sp, #48]
stp x25, x26, [sp, #64]
str x0, [sp, #80]
mov x21, x20
ldr x22, [x19, #16]
mov x0, #0
bl 0x1c1570
ldur x8, [x0, #-8]
ldrb w9, [x8, #80]
add x10, x9, #16
bic x24, x10, x9
ldr x25, [x8, #64]
adrp x0, 0x519000
add x0, x0, #0x848
add x1, x24, x25
orr x2, x9, #7
bl 0x408bd8
mov x23, x0
add x1, x0, x24
mov x0, x22
adrp x2, 0x1c1000
add x2, x2, #0x570
bl 0x1be40
adrp x8, 0x1c6000
add x8, x8, #0xa70
stp x8, x23, [x21, #24]
ldr x0, [sp, #80]
ldp x25, x26, [sp, #64]
ldp x23, x24, [sp, #48]
ldp x21, x22, [sp, #32]
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp], #96
ret
"""
TRAMPOLINE_HEX = "fd7bbaa9fd030091f35301a9f55b02a9f76303a9f96b04a9e02b00f9f50314aa760a40f9000080d2b2dff29708805ff8094141392a4100915801298a192140f980000090002021910103198b220940b242fdfb97f70300aa0100188be00316aac2e5ff9042c01591d649ec97e8e5ffb008c12991a8de01a9e02b40f9f96b44a9f76343a9f55b42a9f35341a9fd7bc6a8c0035fd6"


HIT_TRAMPOLINE_ASSEMBLY = """
stp x9, x10, [sp, #-16]!
mov w9, #1
strb w9, [x20, x8]
ldp x9, x10, [sp], #16
b 0x1ab718
"""
HIT_TRAMPOLINE_HEX = "e92bbfa929008052896a2838e92bc1a8fa87f217"


class InteractionPatchError(ValueError):
    pass


@dataclass(frozen=True)
class Change:
    offset: int
    before: bytes
    after: bytes
    reason: str


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def branch(source: int, target: int, *, link: bool = False) -> bytes:
    displacement = target - source
    if displacement % 4 or not -(1 << 27) <= displacement < (1 << 27):
        raise InteractionPatchError("ARM64 branch is unaligned or out of range")
    return struct.pack("<I", (0x94000000 if link else 0x14000000) | ((displacement // 4) & 0x3FFFFFF))


def branch_target(source: int, encoded: bytes, *, link: bool = False) -> int:
    if len(encoded) != 4:
        raise InteractionPatchError("Expected one ARM64 branch")
    word, = struct.unpack("<I", encoded)
    if word & 0xFC000000 != (0x94000000 if link else 0x14000000):
        raise InteractionPatchError("Unexpected ARM64 branch opcode")
    immediate = word & 0x3FFFFFF
    if immediate & (1 << 25):
        immediate -= 1 << 26
    return source + immediate * 4


def _verify_cave(data: bytes, length: int) -> None:
    magic, cpu, _, filetype, count, size = struct.unpack_from("<6I", data)
    if (magic, cpu, filetype) != (0xFEEDFACF, 0x0100000C, 2):
        raise InteractionPatchError("Expected the original thin arm64 executable")
    cursor, found = 32, False
    for _ in range(count):
        command, length_command = struct.unpack_from("<II", data, cursor)
        if length_command < 8 or cursor + length_command > 32 + size:
            raise InteractionPatchError("Malformed load command")
        if command == 0x19:
            name = data[cursor + 8:cursor + 24].rstrip(b"\0")
            address, vm_size, file_offset, file_size, max_prot, init_prot, sections = struct.unpack_from("<4Q3I", data, cursor + 24)
            if name == b"__TEXT":
                if not (init_prot & 4 and max_prot & 4) or address - file_offset != BASE:
                    raise InteractionPatchError("Cave is not in the expected executable mapping")
                if not (file_offset <= CAVE and CAVE + length <= file_offset + min(file_size, vm_size)):
                    raise InteractionPatchError("Cave exceeds the original executable mapping")
                for index in range(sections):
                    section = cursor + 72 + index * 80
                    section_size, section_offset = struct.unpack_from("<QI", data, section + 40)
                    if section_offset < CAVE + length and CAVE < section_offset + section_size:
                        raise InteractionPatchError("Cave overlaps a defined section")
                found = True
        elif command == 0x2C and struct.unpack_from("<I", data, cursor + 16)[0]:
            raise InteractionPatchError("Encrypted executables are unsupported")
        cursor += length_command
    if not found or any(data[CAVE:CAVE + length]):
        raise InteractionPatchError("Expected unused zero padding in __TEXT")


def patch_plan(original: bytes) -> list[Change]:
    if len(original) != ORIGINAL_BINARY_SIZE or sha256(original) != ORIGINAL_BINARY_SHA256:
        raise InteractionPatchError("Original FreeMusic 4.2.7 executable SHA256 mismatch")
    trampoline = bytes.fromhex(TRAMPOLINE_HEX)
    hit_trampoline = bytes.fromhex(HIT_TRAMPOLINE_HEX)
    _verify_cave(original, HIT_CAVE - CAVE + len(hit_trampoline))
    # These fingerprints also identify the two real UI call sites, the native
    # closure/capture reference, and the native copy function; not a byte search.
    contexts = {
        0x1AB5C4: "9f4a0039000080d2a6670094fa0300aa9ffe01a9082480b9a0f7ffb0",
        0x1A5170: "010100b021403c91e80313aa20008052e2031aaae30318aaf40317aad8820994",
        0x1AAA70: "28008052e84a0039e800009008c12991e8d601a9000080d2776a0094",
        0x1AB70C: "0570f997082480b99f6a2838",
    }
    for offset, expected in contexts.items():
        if original[offset:offset + len(expected) // 2] != bytes.fromhex(expected):
            raise InteractionPatchError(f"Native interaction context mismatch at {offset:#x}")
    changes = [
        Change(SEEK_SITE, bytes.fromhex("9ffe01a9"), branch(SEEK_SITE, CAVE, link=True), "native preview lyric seek capture"),
        Change(EXPAND_COUNT_SITE, bytes.fromhex("20008052"), bytes.fromhex("40008052"), "double-tap preview expansion"),
        Change(HIT_TESTING_SITE, bytes.fromhex("9f6a2838"), branch(HIT_TESTING_SITE, HIT_CAVE), "enable existing preview lyric hit testing"),
        Change(CAVE, bytes(len(trampoline)), trampoline, "native Swift closure capture trampoline"),
        Change(HIT_CAVE, bytes(len(hit_trampoline)), hit_trampoline, "register-preserving preview hit-testing trampoline"),
    ]
    for change in changes:
        if original[change.offset:change.offset + len(change.before)] != change.before:
            raise InteractionPatchError(f"Original bytes mismatch at {change.offset:#x}")
    if branch_target(SEEK_SITE, changes[0].after, link=True) != CAVE:
        raise InteractionPatchError("Patched call target mismatch")
    return changes


def apply_verified_plan(data: bytes, changes: list[Change]) -> bytes:
    """Apply a plan obtained from the original, allowing other disjoint patches."""
    output = bytearray(data)
    previous_end = 0
    for change in sorted(changes, key=lambda item: item.offset):
        if len(change.before) != len(change.after) or change.offset < previous_end:
            raise InteractionPatchError("Overlapping or resizing changes are prohibited")
        if output[change.offset:change.offset + len(change.before)] != change.before:
            raise InteractionPatchError(f"Refusing unexpected/already-patched bytes at {change.offset:#x}")
        output[change.offset:change.offset + len(change.after)] = change.after
        previous_end = change.offset + len(change.after)
    return bytes(output)


def patch_binary(original: bytes) -> tuple[bytes, dict]:
    changes = patch_plan(original)
    output = apply_verified_plan(original, changes)
    report = {"original_sha256": sha256(original), "patched_sha256": sha256(output),
        "version": "FreeMusic 4.2.7 (4379)", "requires_resigning": True,
        "changes": [{"offset": hex(c.offset), "before": c.before.hex(), "after": c.after.hex(), "reason": c.reason} for c in changes],
        "limits": ["Original IPA has not been executed in the simulator.", "Native UI gesture priority requires on-device validation after valid re-signing."]}
    return output, report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.original.resolve(strict=True)
    output = args.output.absolute()
    if output.resolve() == source or output.exists() or output.is_symlink():
        raise InteractionPatchError("Output must be a new file, distinct from the original")
    patched, report = patch_binary(source.read_bytes())
    with output.open("xb") as handle:
        handle.write(patched)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
