"""Use FullPlayer's existing presentation for its top bar and side gestures."""
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
HEADER_NOTIFY_CAVE = 0x50BE00
ZOOM_LAYOUT_SITE = 0x9E23C
PLAIN_LAYOUT_SITE = 0x9E02C
ZOOM_LAYOUT_CAVE = 0x50BEB4
PLAIN_LAYOUT_CAVE = ZOOM_LAYOUT_CAVE + 28

# PlayerZoomDestination's body has two original paths. Zoom owns an AnyView
# already. The plain path copies its unchanged content into the return buffer
# (normal value witness). AnyView.init consumes that copy only when the gesture
# wrapper is available. Both then use the original AnyView enum case. When
# the wrapper is missing, plain content keeps its original case and identity.
# Normal and reduced motion retain the host's original navigation choices.
LAYOUT_ASSEMBLY = """
str x20, [x19]
bl lookup
cbz x0, zoom_done
mov x8, x0
mov x0, x19
blr x8
zoom_done:
b 0x9e240
plain:
mov x28, x2
blr x8
bl lookup
cbnz x0, wrap_plain
b 0x9e030
wrap_plain:
mov x24, x0
adrp x0, 0x54f000
add x0, x0, #0x6f8
adrp x1, 0x54f000
add x1, x1, #0x6e0
adrp x2, 0x419000
add x2, x2, #0xcd8
adrp x3, 0x535000
ldr x3, [x3, #0xc80]
bl 0xed80
mov x2, x0
mov x1, x28
mov x0, x19
bl 0x406500
str x0, [x19]
mov x0, x19
blr x24
mov x8, sp
stur x8, [x29, #-0x78]
b 0x9e240
lookup:
mov x0, #-2
adr x1, symbol
b 0x40821c
symbol:
"""
LAYOUT_CODE = bytes.fromhex("740200f91f000094800000b4e80300aae00313aa00013fd6dd48ee17fc0302aa00013fd617000094400000b55448ee17f80300aa2002009000e01b912102009021801b9162f8ffd042603391430100d0634046f99e0bec97e20300aae1031caae00313aa7ae9fb97600200f9e00313aa00033fd6e8030091a88318f8c448ee172000809241000010b8f0fb17")
LAYOUT_SYMBOL = b"FMXAttachLyricTextLayout\0"

# Runs only after the original top bar has accepted a drag. Its prologue
# already saved LR and the native drag remains borrowed in callee-saved x20.
# The last two instructions replay the displaced mov x0,#0 and continue with
# the unmodified native PresentationMode dismissal, even without our observer.
HEADER_NOTIFY_ASSEMBLY = """
mov x0, #-2
adr x1, symbol
bl 0x40821c
cbz x0, native
mov x8, x0
mov x0, x20
blr x8
native:
mov x0, #0
b 0x1abb48
symbol:
"""
HEADER_NOTIFY_CODE = bytes.fromhex("200080920101001005f1fb97800000b4e80300aae00314aa00013fd6000080d24a7ff217")
HEADER_NOTIFY_SYMBOL = b"FMXPlayerHeaderWillDismiss\0"

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
    0x1AA918: "28008052e84a0039e800009008811991e8d601a9",
}

# Only fingerprints of the additional native layout and drag callback context
# are distributed. The actual bytes are checked against the owner's local IPA.
PLAYER_LAYOUT_DIGESTS = {
    # Native source/return ownership, conditional tags, and the concrete
    # ModifiedContent<FullPlayerView...,PlayerZoomDestination> type lineage.
    0x9DFA8: (44, "f5c0040c7b2c53edc983eff2d94125ced9f14e1f2e379231fc906831654e8d67"),
    0x9DFDC: (148, "731832298560fad3e5779700ed4b1a4f5391f34e59035228992f0b3802868388"),
    0x9E140: (68, "163cda789e254ec143d2945658005ce3c8773bf02628c4c4cf9c0f161e88c68d"),
    0x9E1E0: (172, "2ce7ce22d99a86b4bec43eeab74d55845b44b1b746753dae82cbfc45f6872305"),
    0x44D348: (16, "88bd5f1b16163fdcd7d6afd76a0c4fa49d61bbc09169f813dc3980476756602d"),
    0x5329E0: (8, "1b3fa6a4631eef263acadd3ebefc4b160d299934894e226adf7638024441c334"),
    0x43E520: (24, "167d7890a3c7d936f1a6599cb97854dc70334f8353edb21843fb9c1e4efd5519"),
    0x440614: (24, "faacac0bceb7d8d2801ad54d06b3b6ef27afb029f04a9313be3165b21fe26909"),

}


def patch_plan(original: bytes) -> list[Change]:
    """Plan against the immutable original; parent merges disjoint changes."""
    if len(original) != ORIGINAL_BINARY_SIZE or sha256(original) != ORIGINAL_BINARY_SHA256:
        raise InteractionPatchError("Original FreeMusic 4.2.9 executable SHA256 mismatch")
    trampoline = bytes.fromhex(TRAMPOLINE_HEX)
    bridges = HEADER_NOTIFY_CODE + HEADER_NOTIFY_SYMBOL
    layout_offset = ZOOM_LAYOUT_CAVE - HEADER_NOTIFY_CAVE
    if len(bridges) > layout_offset:
        raise InteractionPatchError("Player gesture bridge ranges overlap")
    bridges = bridges.ljust(layout_offset, b'\0') + LAYOUT_CODE + LAYOUT_SYMBOL
    # The shared validator checks the complete zero-padding interval, executable
    # __TEXT permissions, no section overlap, and absence of encryption.
    _verify_cave(original, HEADER_NOTIFY_CAVE + len(bridges) - LYRIC_CAVE)
    for offset, (length, digest) in PLAYER_LAYOUT_DIGESTS.items():
        if sha256(original[offset:offset + length]) != digest:
            raise InteractionPatchError(f"Native player layout context mismatch at {offset:#x}")
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
        Change(ZOOM_LAYOUT_SITE, original[ZOOM_LAYOUT_SITE:ZOOM_LAYOUT_SITE + 4],
               branch(ZOOM_LAYOUT_SITE, ZOOM_LAYOUT_CAVE), "wrap the zoomed player in its gesture scope"),
        Change(PLAIN_LAYOUT_SITE, original[PLAIN_LAYOUT_SITE:PLAIN_LAYOUT_SITE + 4],
               branch(PLAIN_LAYOUT_SITE, PLAIN_LAYOUT_CAVE), "wrap the plain player, including reduced motion, in its gesture scope"),
        Change(NATIVE_DISMISS, bytes.fromhex(NATIVE_DISMISS_HEX)[:4],
               branch(NATIVE_DISMISS, HEADER_NOTIFY_CAVE), "give the existing header dismissal precedence"),
        Change(HEADER_NOTIFY_CAVE, bytes(len(bridges)), bridges,
               "install whole-player gesture on both presentation paths; coordinate native header dismissal"),
    ]


def patch_binary(original: bytes) -> tuple[bytes, dict]:
    changes = patch_plan(original)
    result = apply_verified_plan(original, changes)
    return result, {
        "original_sha256": sha256(original), "patched_sha256": sha256(result),
        "version": "FreeMusic 4.2.9 (4381)", "requires_resigning": True,
        "scope": "existing FullPlayer top gestures and the presented player surface",
        "lyric_down_condition": "start in the left or right third of the visible player, dy > 144, dy > 2 * abs(dx)",
        "left_condition": "dx < -80 and -dx > 1.5 * abs(dy)",
        "original_downward_condition_preserved": True,
        "native_presentation_binding_preserved": True,
        "changes": [{"offset": hex(c.offset), "before": c.before.hex(),
                     "after": c.after.hex(), "reason": c.reason} for c in changes],
        "limits": ["The middle third retains normal scrolling. Original top-bar dismissal remains available.",
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
