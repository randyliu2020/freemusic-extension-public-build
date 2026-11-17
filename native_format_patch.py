"""Exact-build manual-download final-save bridge; original code is never published.

The only replaced instruction calls NSFileManager's move method. The authored
bridge passes its existing Objective-C objects/error pointer to a narrow C export
and preserves the native success/failure continuation and library registration.
"""
from interaction_patch import (ORIGINAL_BINARY_SHA256, ORIGINAL_BINARY_SIZE, BASE,
    Change, InteractionPatchError, branch, sha256, _verify_cave, CAVE as SHARED_CAVE)

CAVE = 0x509D40
END = 0x509E40
SITE = 0x7ACDC
CONTINUATION = SITE + 4
ORIGINAL_MOVE = 0x40C740
DYLSYM = 0x40805C
EXPORT_NAME = 0x509DF0
MARKER = 0x509E10
CONTEXTS = {
    0x7AA50: (0x4D4, "efe92622b926885d8d5eb32585c284e1f99811baf6dcf0a28a80756fd0a2074e"),
}
ASSEMBLY = {CAVE: """
stp x29, x30, [sp, #-64]!
stp x0, x1, [sp, #16]
stp x2, x3, [sp, #32]
str x4, [sp, #48]
mov x0, #-2
adrp x1, 0x509000
add x1, x1, #0xdf0
bl 0x40805c
cbz x0, native
mov x16, x0
ldr x0, [sp, #16]
ldp x1, x2, [sp, #32]
ldr x3, [sp, #48]
blr x16
b done
native:
ldp x0, x1, [sp, #16]
ldp x2, x3, [sp, #32]
ldr x4, [sp, #48]
bl 0x40c740
done:
ldp x29, x30, [sp], #64
b 0x7ace0
"""}
ENCODED = {5283136: 'fd7bbca9e00701a9e20f02a9e41b00f9200080920100009021c03791c0f8fb97e00000b4f00300aae00b40f9e10b42a9e31b40f900023fd605000014e00741a9e20f42a9e41b40f96e0afc97fd7bc4a8d4c3ed17'}

def payload():
    data = bytearray(END-CAVE)
    chunks = {offset: bytes.fromhex(value) for offset,value in ENCODED.items()}
    chunks.update({EXPORT_NAME:b"FMDownloadNativeMove\0", MARKER:b"FMX-NATIVE-DOWNLOAD-FORMAT-v1\0"})
    used = set()
    for offset,value in chunks.items():
        occupied=set(range(offset,offset+len(value)))
        if offset<CAVE or offset+len(value)>END or used & occupied:
            raise InteractionPatchError("Native format trampoline overlaps")
        used |= occupied
        data[offset-CAVE:offset-CAVE+len(value)] = value
    return bytes(data)

def patch_plan(original: bytes):
    if len(original)!=ORIGINAL_BINARY_SIZE or sha256(original)!=ORIGINAL_BINARY_SHA256:
        raise InteractionPatchError("Unsupported original FreeMusic binary for native format bridge")
    _verify_cave(original, END-SHARED_CAVE)
    for offset,(length,digest) in CONTEXTS.items():
        if sha256(original[offset:offset+length])!=digest:
            raise InteractionPatchError(f"Native final-save context mismatch at {offset:#x}")
    return [Change(SITE,original[SITE:SITE+4],branch(SITE,CAVE),"manual final-save uses verified media container extension"),
            Change(CAVE,bytes(END-CAVE),payload(),"versioned narrow native format bridge")]
