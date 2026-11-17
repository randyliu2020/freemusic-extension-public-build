"""Notify the extension after the host commits a new playback UUID.

Only an authored bridge and whole-build/context hashes are distributed. The
native queue, shuffle order, UUID guards and preloading implementation remain.
"""
from interaction_patch import (ORIGINAL_BINARY_SHA256, ORIGINAL_BINARY_SIZE, BASE,
    Change, InteractionPatchError, branch, sha256, _verify_cave, CAVE as SHARED_CAVE)

CAVE = 0x509E40
END = 0x509F40
SITE = 0x4FD90
CONTINUATION = SITE + 4
DYLSYM = 0x40805C
EXPORT_NAME = 0x509EF0
MARKER = 0x509F18
CONTEXTS = {
    0x4FD94: (0x30, "e007ea652ca53dbeb857541edacfde43e2c7515b91e0495637c4661f971e537c"),
    0x4A4E0: (0x518, "74cd8e8624e72f34fb1fbc4c12c2305c113191da532dac0cfed41cdc50302cbb"),
    0x51050: (0x450, "2f2d17c39f7af77d904c00644fc5bb4a6a1735f2feacc8d753d36aadf3fbc98f"),
    0x575D4: (0x22C, "12048925a808df1e27fe97ab3091383972cfadfd53c49add9066805d0ee5c941"),
    0x56E20: (0x7B4, "f0731e9c38a59df154c4fb2160e2cd1055d3c5c849c512c14fcfc6233785dff3"),
}
ASSEMBLY = {CAVE: """
stp x29, x30, [sp, #-112]!
stp x0, x1, [sp, #16]
stp x2, x3, [sp, #32]
stp x4, x5, [sp, #48]
stp x6, x7, [sp, #64]
str x8, [sp, #80]
mov x0, #-2
adrp x1, 0x509000
add x1, x1, #0xef0
bl 0x40805c
cbz x0, restore
mov x16, x0
mov x0, x20
blr x16
restore:
ldp x0, x1, [sp, #16]
ldp x2, x3, [sp, #32]
ldp x4, x5, [sp, #48]
ldp x6, x7, [sp, #64]
ldr x8, [sp, #80]
ldp x29, x30, [sp], #112
stp d9, d8, [sp, #-112]!
b 0x4fd94
"""}
ENCODED = {5283392: 'fd7bb9a9e00701a9e20f02a9e41703a9e61f04a9e82b00f9200080920100009021c03b917ef8fb97800000b4f00300aae00314aa00023fd6e00741a9e20f42a9e41743a9e61f44a9e82b40f9fd7bc7a8e923b96dc017ed17'}

def payload():
    result=bytearray(END-CAVE)
    chunks={offset:bytes.fromhex(value) for offset,value in ENCODED.items()}
    chunks.update({EXPORT_NAME:b"FMPlaybackSequenceNativeSelection\0",MARKER:b"FMX-PLAYBACK-SEQUENCE-v1\0"})
    occupied=set()
    for offset,value in chunks.items():
        used=set(range(offset,offset+len(value)))
        if offset<CAVE or offset+len(value)>END or occupied & used:
            raise InteractionPatchError("Playback sequence bridge overlap")
        occupied |= used
        result[offset-CAVE:offset-CAVE+len(value)]=value
    return bytes(result)

def patch_plan(original: bytes):
    if len(original)!=ORIGINAL_BINARY_SIZE or sha256(original)!=ORIGINAL_BINARY_SHA256:
        raise InteractionPatchError("Unsupported original FreeMusic binary for playback sequence")
    _verify_cave(original,END-SHARED_CAVE)
    for offset,(length,digest) in CONTEXTS.items():
        if sha256(original[offset:offset+length])!=digest:
            raise InteractionPatchError(f"Playback sequence context mismatch at {offset:#x}")
    return [Change(SITE,original[SITE:SITE+4],branch(SITE,CAVE),"retire old extension work after native selection UUID commit"),
            Change(CAVE,bytes(END-CAVE),payload(),"versioned native playback selection bridge")]
