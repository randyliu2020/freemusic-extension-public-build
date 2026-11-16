"""Add left swipe to the ORIGINAL FullPlayer top-bar dismissal gesture.

No UIKit modal is dismissed, no state is fabricated, and no gesture is installed
over lyrics or controls. The original SwiftUI PresentationMode/Binding close
path and its original downward condition remain intact. Input is never changed.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from interaction_patch import (
    ORIGINAL_BINARY_SHA256, ORIGINAL_BINARY_SIZE, BASE, Change,
    InteractionPatchError, apply_verified_plan, branch, branch_target, sha256,
    _verify_cave,
    CAVE as LYRIC_CAVE,
)

SITE = 0x1ABC70
CAVE = 0x509740  # after the lyric patch's 0x509720..0x509734 allocation
ORIGINAL_CONDITION = 0x1ABC74
NATIVE_DISMISS = 0x1ABC9C
TRANSLATION_GETTER = 0x404C24

# The original onEnded has saved LR and all callee-saved FP registers already.
# translation returns dx/dy in d0/d1. Only caller-saved d2/d3/d4 and x8 are used;
# d0/d1 and x19/x20 (native view capture / DragGesture.Value) remain unchanged.
# Failed left tests resume the EXACT old predicate after its translation call.
# Successful tests enter the EXACT old PresentationMode.dismiss + Binding write.
TRAMPOLINE_ASSEMBLY = """
bl 0x404c24
fneg d2, d0
mov x8, #0x4054000000000000
fmov d3, x8
fcmp d2, d3
b.le fallback
fabs d3, d1
fmov d4, #1.5
fmul d3, d3, d4
fcmp d2, d3
b.le fallback
b 0x1abc9c
fallback:
b 0x1abc74
"""
TRAMPOLINE_HEX = "39edfb970240611e880ae8d20301679e4020631eed00005423c0601e04106f1e6308641e4020631e4d0000544c89f2174189f217"
ORIGINAL_PREDICATE_HEX = "ed630994880ae8d20001679e2020601ead030054e8630994281ca14ee663099400c0601e0020681ee5020054"
NATIVE_DISMISS_HEX = "000080d234560094081c80b97402088be80317aa0104fd97e80315aae00316aaf40317aaa3690994f40315aa2d650994e00315aae10316aaf40317aaa0690994211d00d021201891821300b042801791e00317aa3e72f997"
CONTEXTS = {
    SITE: ORIGINAL_PREDICATE_HEX,
    NATIVE_DISMISS: NATIVE_DISMISS_HEX,
    # Two already-existing top-bar modifiers use this one native view capture.
    0x1C6A18: "c1fffff021c0159122ffffb042702f9141040014",
    0x1D236C: "abd1ff17",
    0x1A4ECC: "21b047f9f888f997e30300aa000100d000602891b50353f8e80315aae10313aab68354f8e20316aa3d850994",
    0x1A48C8: "21b047f9798af997e30300aa600100d000b00d91a8c302d1130150f8e80313aae10317aaa94302d1380150f8e20318aabc860994",
}


def patch_plan(original: bytes) -> list[Change]:
    """Plan against the immutable original; parent merges disjoint changes."""
    if len(original) != ORIGINAL_BINARY_SIZE or sha256(original) != ORIGINAL_BINARY_SHA256:
        raise InteractionPatchError("Original FreeMusic 4.2.7 executable SHA256 mismatch")
    trampoline = bytes.fromhex(TRAMPOLINE_HEX)
    # The shared validator checks the complete zero-padding interval, executable
    # __TEXT permissions, no section overlap, and absence of encryption.
    _verify_cave(original, CAVE + len(trampoline) - LYRIC_CAVE)
    for offset, expected_hex in CONTEXTS.items():
        expected = bytes.fromhex(expected_hex)
        if original[offset:offset + len(expected)] != expected:
            raise InteractionPatchError(f"Native player dismissal context mismatch at {offset:#x}")
    jump = branch(SITE, CAVE)
    if branch_target(SITE, jump) != CAVE:
        raise InteractionPatchError("Player gesture branch target mismatch")
    return [
        Change(SITE, bytes.fromhex(ORIGINAL_PREDICATE_HEX)[:4], jump,
               "extend native top-bar dismissal with left-swipe condition"),
        Change(CAVE, bytes(len(trampoline)), trampoline,
               "left threshold OR unmodified native downward dismissal"),
    ]


def patch_binary(original: bytes) -> tuple[bytes, dict]:
    changes = patch_plan(original)
    result = apply_verified_plan(original, changes)
    return result, {
        "original_sha256": sha256(original), "patched_sha256": sha256(result),
        "version": "FreeMusic 4.2.7 (4379)", "requires_resigning": True,
        "scope": "existing FullPlayer top drag-handle and title-bar gestures only",
        "left_condition": "dx < -80 and -dx > 1.5 * abs(dy)",
        "original_downward_condition_preserved": True,
        "native_presentation_binding_preserved": True,
        "changes": [{"offset": hex(c.offset), "before": c.before.hex(),
                     "after": c.after.hex(), "reason": c.reason} for c in changes],
        "limits": ["Does not add whole-screen swiping over lyrics or sliders.",
                   "Equivalent SwiftUI real-input tests do not execute the original IPA.",
                   "Original app requires device verification after valid re-signing."],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.original.resolve(strict=True)
    output = args.output.absolute()
    if output.resolve() == source or output.exists() or output.is_symlink():
        raise InteractionPatchError("Output must be a new file distinct from the original")
    patched, report = patch_binary(source.read_bytes())
    with output.open("xb") as handle:
        handle.write(patched)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
