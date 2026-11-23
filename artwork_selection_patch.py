"""Exact-build missing-cover identity cleanup; no original app bytes are bundled.

Only the native nil/empty URL branches are replaced. Normal nonempty artwork
requests retain the original path and URL guard. The missing path clears both
owned fields through the production Swift/ObjC ownership bridge before the
native metadata publication resumes.
"""
from interaction_patch import (ORIGINAL_BINARY_SHA256, ORIGINAL_BINARY_SIZE, BASE,
    Change, InteractionPatchError, branch, sha256, _verify_cave, CAVE as SHARED_CAVE)

CAVE = 0x509F40
END = 0x50A000
NIL_SITE = 0x64180
EMPTY_SITE = 0x64194
MISSING_CONTINUATION = 0x641e4
DYLSYM = 0x40821c
EXPORT_NAME = 0x509FF8
ARTWORK_IVAR = 0x54d838
URL_IVAR = 0x54d840
CONTEXTS = {
    0x64158: (0x90, "c39bb368ae048436131070b6911ac0b08d432c049c21f1776db7d310ead34c45"),
    0x63280: (0x40, "f656cc5042a61214daf6ead89f7853a48f8ab49d998e8d123abaed01a439ba88"),
    0x54d838: (0x10, "374708fff7719dd5979ec875d56cd2286f6d3cf7ec317a3b25632aab28ec37bb"),
}
ASSEMBLY = {CAVE: """
cbz x26, missing
b 0x64184
cbz x8, missing
b 0x64198
missing:
stp x0, x1, [sp, #-288]!
stp x2, x3, [sp, #16]
stp x4, x5, [sp, #32]
stp x6, x7, [sp, #48]
stp x8, x9, [sp, #64]
stp x10, x11, [sp, #80]
stp x12, x13, [sp, #96]
stp x14, x15, [sp, #112]
stp x16, x17, [sp, #128]
stp x18, x30, [sp, #144]
stp q0, q1, [sp, #160]
stp q2, q3, [sp, #192]
stp q4, q5, [sp, #224]
stp q6, q7, [sp, #256]
mov x0, #-2
adrp x1, 0x509000
add x1, x1, #0xff8
bl 0x40821c
cbz x0, done
mov x16, x0
adrp x9, 0x54d000
ldr x10, [x9, #0x840]
add x0, x21, x10
ldr x10, [x9, #0x838]
add x1, x21, x10
blr x16
done:
ldp q6, q7, [sp, #256]
ldp q4, q5, [sp, #224]
ldp q2, q3, [sp, #192]
ldp q0, q1, [sp, #160]
ldp x18, x30, [sp, #144]
ldp x16, x17, [sp, #128]
ldp x14, x15, [sp, #112]
ldp x12, x13, [sp, #96]
ldp x10, x11, [sp, #80]
ldp x8, x9, [sp, #64]
ldp x6, x7, [sp, #48]
ldp x4, x5, [sp, #32]
ldp x2, x3, [sp, #16]
ldp x0, x1, [sp], #288
b 0x641e4
"""}
ENCODED = {
    0x509f40: '9a0000b49068ed17480000b49368ed17e007aea9e20f01a9e41702a9e61f03a9e82704a9ea2f05a9ec3706a9ee3f07a9f04708a9f27b09a9e00705ade20f06ade41707ade61f08ad200080920100009021e03f91a2f8fb97000100b4f00300aa290200902a2144f9a0020a8b2a1d44f9a1020a8b00023fd6e61f48ade41747ade20f46ade00745adf27b49a9f04748a9ee3f47a9ec3746a9ea2f45a9e82744a9e61f43a9e41742a9e20f41a9e007d2a87d68ed17',
}

def payload():
    result = bytearray(END-CAVE)
    chunks = {offset: bytes.fromhex(value) for offset, value in ENCODED.items()}
    chunks[EXPORT_NAME] = b"FMXAC\0"
    occupied = set()
    for offset, value in chunks.items():
        used = set(range(offset, offset+len(value)))
        if offset < CAVE or offset+len(value) > END or occupied & used:
            raise InteractionPatchError("Missing-cover bridge overlaps a reserved region")
        occupied |= used
        result[offset-CAVE:offset-CAVE+len(value)] = value
    return bytes(result)

def patch_plan(original: bytes):
    if len(original) != ORIGINAL_BINARY_SIZE or sha256(original) != ORIGINAL_BINARY_SHA256:
        raise InteractionPatchError("Unsupported original FreeMusic binary for artwork selection bridge")
    _verify_cave(original, END-SHARED_CAVE)
    for offset, (length, digest) in CONTEXTS.items():
        if sha256(original[offset:offset+length]) != digest:
            raise InteractionPatchError(f"Native missing-cover context mismatch at {offset:#x}")
    return [Change(NIL_SITE, original[NIL_SITE:NIL_SITE+4], branch(NIL_SITE, CAVE), "clear stale artwork identity for absent native cover URL"),
            Change(EMPTY_SITE, original[EMPTY_SITE:EMPTY_SITE+4], branch(EMPTY_SITE, CAVE+8), "clear stale artwork identity for empty native cover URL"),
            Change(CAVE, bytes(END-CAVE), payload(), "narrow native artwork ownership bridge")]
