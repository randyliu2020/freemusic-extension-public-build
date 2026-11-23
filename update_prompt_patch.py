"""Suppress the optional launch announcement, keeping manual checks functional.

FreeMusic 4.2.9 shares its update presenter between startup and the settings
button. The pending callbacks distinguish them, even if both share one request.
This presentation-only change runs after the host accepted an update result.
"""
import hashlib

from interaction_patch import Change, InteractionPatchError, branch


ORIGINAL_SHA = "59bb22eb6fb7a62bf574e8b42c9a16f1b3774368bda484a41ce9bea4b8af992f"
PRESENT_CALL = 0x2E778
PRESENTER = 0x2E80C
CAVE = 0x50BF80

# x0 is the borrowed update result. x20 is AppUpdateChecker. All writes are
# to scratch registers. The existing call provides the return address for both
# the quiet return and the tail branch to the unmodified host presenter.
ASSEMBLY = """
    ldrb w8, [x0, #0x38]
    tbnz w8, #0, present
    adrp x8, 0x54c000
    ldr x8, [x8, #0xda0]
    ldr x8, [x20, x8]
    ldr x9, [x8, #0x10]
    cmp x9, #1
    b.ne present
    ldp x9, x10, [x8, #0x20]
    adrp x11, 0x31000
    add x11, x11, #0x794
    cmp x9, x11
    b.ne present
    cbz x10, present
    ldp x8, x10, [x10, #0x10]
    cbnz x10, present
    adrp x11, 0x7000
    add x11, x11, #0xb9c
    cmp x8, x11
    b.ne present
    ret
present:
    b 0x2e80c
"""
PAYLOAD = bytes.fromhex(
    "08e0403988020037080200b008d146f9886a68f8090940f93f0500f1c1010054"
    "092942a92bd9ffd06b511e913f010beb210100540a0100b4482941a9ca0000b5"
    "ebd7ff906b712e911f010beb41000054c0035fd60e8aec17"
)


def patch_plan(original: bytes):
    if hashlib.sha256(original).hexdigest() != ORIGINAL_SHA:
        raise InteractionPatchError("Unknown executable for the 4.2.9 update presenter")
    if (original[PRESENT_CALL:PRESENT_CALL+4] != branch(PRESENT_CALL, PRESENTER, link=True)
            or original[CAVE:CAVE+len(PAYLOAD)] != bytes(len(PAYLOAD))):
        raise InteractionPatchError("Unexpected update presentation call or reserved space")
    return [
        Change(PRESENT_CALL, original[PRESENT_CALL:PRESENT_CALL+4], branch(PRESENT_CALL, CAVE, link=True),
               "Classify an optional update by the actual pending callback"),
        Change(CAVE, bytes(len(PAYLOAD)), PAYLOAD,
               "Quiet launch-only updates while retaining manual and mandatory presentation"),
    ]
