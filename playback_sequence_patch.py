"""Notify the extension after the host commits a new playback UUID.

Only an authored bridge and whole-build/context hashes are distributed. The
native queue, shuffle order, UUID guards and preloading implementation remain.
"""
from interaction_patch import (ORIGINAL_BINARY_SHA256, ORIGINAL_BINARY_SIZE, BASE,
    Change, InteractionPatchError, branch, sha256, _verify_cave, CAVE as SHARED_CAVE)

CAVE = 0x509E40
END = 0x509F40
SITE = 0x4fec8
CONTINUATION = SITE + 4
DYLSYM = 0x40821c
EXPORT_NAME = 0x509EF0
MARKER = 0x509F18
CONTEXTS = {
    0x4fecc: (0x30, "ce96b7b35fb5fb0bc32900557f1fa71c33f474d6c6cf93d50acf12333a3649ed"),
    0x4a698: (0x518, "a114ce52627b7b0f51cb28a66673a90b2ae3e5c26be75c82d8dc049b6bc0b2cc"),
    0x51040: (0x450, "c9282962d6285945849186709e07209d5cb4141fee4f5732060804094b8f8299"),
    0x5758c: (0x22c, "5ca0e4765af7c15cee76d3001d03180dd54697f4dde0df615f14b505f2ea2585"),
    0x56e18: (0x774, "99efc99267e29b9557f17da9f0fd85dfa97d092ac6db2bba4ba3d442fe6191f7"),
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
bl 0x40821c
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
b 0x4fecc
"""}
ENCODED = {
    0x509e40: 'fd7bb9a9e00701a9e20f02a9e41703a9e61f04a9e82b00f9200080920100009021c03b91eef8fb97800000b4f00300aae00314aa00023fd6e00741a9e20f42a9e41743a9e61f44a9e82b40f9fd7bc7a8e923b96d0e18ed17',
}

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
