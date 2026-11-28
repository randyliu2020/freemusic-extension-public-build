"""Use FullPlayer's existing SwiftUI actions for top-bar and lyric dismissal."""
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

SITE = 0x1ABB18
CAVE = 0x509740  # after the lyric patch's 0x509720..0x509734 allocation
ORIGINAL_CONDITION = 0x1ABB1C
NATIVE_DISMISS = 0x1ABB44
TRANSLATION_GETTER = 0x404DE4
LYRIC_END_SITE = 0x1CD628
LYRIC_END_CAVE = 0x50BE00
LYRIC_NATIVE_ENDED = 0x1BD608
FULL_PLAYER_SEEK = 0x1C6660
FULL_PLAYER_DRAG = 0x1C6608

# The original LyricsScroller attaches simultaneous DragGesture.onChanged.onEnded.
# Its thunk passes the original gesture value (x0) and borrowed LyricsScroller (x1).
# Run its original end action, preserving completion of a normal scroll. Only the
# FullPlayer onSeek closure holds the validated native FullPlayer value, the same
# capture layout as the top-bar gesture. Passing its capture and the original
# DragGesture.Value invokes the ordinary host dismissal, with native ARC ownership.
LYRIC_END_ASSEMBLY = """
stp x19, x20, [sp, #-32]!
stp x21, x30, [sp, #16]
mov x19, x0
mov x21, x1
bl 0x1bd608
ldr x9, [x21, #24]
adrp x8, 0x1c6000
add x8, x8, #0x660
cmp x9, x8
b.ne finished
ldr x8, [x21, #32]
cbz x8, finished
mov x20, x19
bl 0x404de4
mov x8, #0x4062000000000000
fmov d2, x8
fcmp d1, d2
b.le finished
fabs d2, d0
fadd d2, d2, d2
fcmp d1, d2
b.le finished
mov x0, x19
ldr x20, [x21, #32]
bl 0x1c6608
finished:
ldp x21, x30, [sp, #16]
ldp x19, x20, [sp], #32
ret
"""
LYRIC_END_HEX = "f353bea9f57b01a9f30300aaf50301aafec5f297a90e40f9c8e5fff0088119913f0108eb01020054a81240f9c80100b4f40313aaece3fb97480ce8d20201679e2020621e0d01005402c0601e4228621e2020621e8d000054e00313aab41240f9eae9f297f57b41a9f353c2a8c0035fd6"
LYRIC_END_REDIRECT = bytes.fromhex("e21900d042003891")

# The original onEnded has saved LR and all callee-saved FP registers already.
# translation returns dx/dy in d0/d1. Only caller-saved d2/d3/d4 and x8 are used;
# d0/d1 and x19/x20 (native view capture / DragGesture.Value) remain unchanged.
# Failed left tests resume the EXACT old predicate after its translation call.
# Successful tests enter the EXACT old PresentationMode.dismiss + Binding write.
TRAMPOLINE_ASSEMBLY = """
bl 0x404de4
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
b 0x1abb44
fallback:
b 0x1abb1c
"""
TRAMPOLINE_HEX = "a9edfb970240611e880ae8d20301679e4020631eed00005423c0601e04106f1e6308641e4020631e4d000054f688f217eb88f217"
ORIGINAL_PREDICATE_HEX = "b3640994880ae8d20001679e2020601ead030054ae640994281ca14eac64099400c0601e0020681ee5020054"
NATIVE_DISMISS_HEX = "000080d288550094081c80b97402088be80317aaa005fd97e80315aae00316aaf40317aa696a0994f40315aaf3650994e00315aae10316aaf40317aa666a0994211d00d021a01a91821300b042801e91e00317aa9472f997"
CONTEXTS = {
    SITE: ORIGINAL_PREDICATE_HEX,
    NATIVE_DISMISS: NATIVE_DISMISS_HEX,
    # Two already-existing top-bar modifiers use this one native view capture.
    0x1C6608: "c1fffff021a0059122ffffb042102a9141040014",
    0x1D2574: "25d0ff17",
    0x1A4DB8: "216447f93d89f997e30300aa000100d000201891b50353f8e80315aae10313aab68354f8e20316aaf2850994",
    0x1A47B4: "216447f9be8af997e30300aa600100d000d01591a8c302d1130150f8e80313aae10317aaa94302d1380150f8e20318aa71870994",
    0x1BC510: "800000b000801891a88302d1150150f8e80315aae10313aaa92302d1370150f8e20317aaf40316aa1c280994",
    0x1CD620: "c1ffff902170019182ffff90422018913be8ff17",
    0x1C771C: "ffc300d1f44f01a9fd7b02a9fd830091e20700f9f30300aa000080d220003fd608805ff808414139094100912801288a8102088be00313aae20740f9fd7b42a9f44f41a9ffc3009140001fd6",
    LYRIC_NATIVE_ENDED: "fc6fbaa9fa6701a9f85f02a9f65703a9f44f04a9fd7b05a9fd430191",
    0x1AA918: "28008052e84a0039e800009008811991e8d601a9",
}


def patch_plan(original: bytes) -> list[Change]:
    """Plan against the immutable original; parent merges disjoint changes."""
    if len(original) != ORIGINAL_BINARY_SIZE or sha256(original) != ORIGINAL_BINARY_SHA256:
        raise InteractionPatchError("Original FreeMusic 4.2.9 executable SHA256 mismatch")
    trampoline = bytes.fromhex(TRAMPOLINE_HEX)
    lyric_end = bytes.fromhex(LYRIC_END_HEX)
    # The shared validator checks the complete zero-padding interval, executable
    # __TEXT permissions, no section overlap, and absence of encryption.
    _verify_cave(original, LYRIC_END_CAVE + len(lyric_end) - LYRIC_CAVE)
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
        Change(LYRIC_END_SITE, original[LYRIC_END_SITE:LYRIC_END_SITE+8], LYRIC_END_REDIRECT,
               "extend the existing lyric scroll-ended action"),
        Change(LYRIC_END_CAVE, bytes(len(lyric_end)), lyric_end,
               "deliberate downward FullPlayer lyric drag invokes its native dismissal"),
    ]


def patch_binary(original: bytes) -> tuple[bytes, dict]:
    changes = patch_plan(original)
    result = apply_verified_plan(original, changes)
    return result, {
        "original_sha256": sha256(original), "patched_sha256": sha256(result),
        "version": "FreeMusic 4.2.9 (4381)", "requires_resigning": True,
        "scope": "existing FullPlayer top gestures and FullPlayer-owned lyric scroller",
        "lyric_down_condition": "dy > 144 and dy > 2 * abs(dx)",
        "left_condition": "dx < -80 and -dx > 1.5 * abs(dy)",
        "original_downward_condition_preserved": True,
        "native_presentation_binding_preserved": True,
        "changes": [{"offset": hex(c.offset), "before": c.before.hex(),
                     "after": c.after.hex(), "reason": c.reason} for c in changes],
        "limits": ["Only the existing lyric gesture with a verified FullPlayer seek owner can close the player.",
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
