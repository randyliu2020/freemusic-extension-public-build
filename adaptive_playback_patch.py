"""Exact-build host integration for adaptive JS playback; never rewrites an IPA in place.
Only authored trampoline bytes and hashes are distributed, not original app code.
"""
from interaction_patch import (ORIGINAL_BINARY_SHA256, ORIGINAL_BINARY_SIZE, BASE,
    Change, InteractionPatchError, apply_verified_plan, branch, sha256,
    _verify_cave, CAVE as SHARED_CAVE)
CAVE=0x509B40
END=0x509D40
DYLSYM=0x40805C
SETUP_SITE=0x58B68
FAILURE_SITE=0x5AAE0
SETUP_NAME=0x509CC0
FAILURE_NAME=0x509CF0
ASSEMBLY={
0x509B40: """
stp x29, x30, [sp, #-16]!
mov x0, #-2
adrp x1, 0x509000
add x1, x1, #0xcc0
bl 0x40805c
cbz x0, done
mov x16, x0
mov x0, x19
adrp x8, 0x54d000
ldr x8, [x8, #0x6a0]
ldr x1, [x19, x8]
blr x16
done:
ldp x29, x30, [sp], #16
sub sp, x29, #0x50
b 0x58b6c
""",
0x509BC0: """
stp x29, x30, [sp, #-48]!
stp x0, x1, [sp, #16]
stp x2, x20, [sp, #32]
cmp x0, #1
b.ne native
cbnz x1, native
cmp w2, #4
b.ne native
adrp x9, 0x5a000
add x9, x9, #0x1b8
cmp x30, x9
b.eq media
adrp x9, 0x5a000
add x9, x9, #0xa7c
cmp x30, x9
b.ne native
media:
mov x0, #-2
adrp x1, 0x509000
add x1, x1, #0xcf0
bl 0x40805c
cbz x0, native
mov x16, x0
mov x0, x20
adrp x8, 0x54d000
ldr x8, [x8, #0x6a0]
ldr x1, [x20, x8]
blr x16
cbz w0, native
ldp x2, x20, [sp, #32]
ldp x0, x1, [sp, #16]
ldp x29, x30, [sp], #48
ret
native:
ldp x2, x20, [sp, #32]
ldp x0, x1, [sp, #16]
ldp x29, x30, [sp], #48
stp x28, x27, [sp, #-0x60]!
b 0x5aae4
"""
}
ENCODED={5282624: 'fd7bbfa920008092010000902100339143f9fb97e00000b4f00300aae00313aa28020090085143f9616a68f800023fd6fd7bc1a8bf4301d1fd3bed17', 5282752: 'fd7bbda9e00701a9e25302a91f0400f181030054610300b55f1000712103005489daffb029e10691df0309eba000005489daffb029f12991df0309eb21020054200080920100009021c0339114f9fb97800100b4f00300aae00314aa28020090085143f9816a68f800023fd6a0000034e25342a9e00741a9fd7bc3a8c0035fd6e25342a9e00741a9fd7bc3a8fc6fbaa9a543ed17'}
CONTEXTS={
0x58240:(0x928,"b7e8c08d8ed6b7bc3ce45b00318756a7c3691a19d8389f7cb98c3712c835263d"),
0x58B68:(0x20,"d5289be4ee66b6a148ad520e32d8a7db180cd9575633b08d817b70836f5b4eb2"),
0x5AAE0:(0x2c,"77daf1b0cad0d4d27b3cadedf18dd3fadc79523cd66e1399f226048c9914849c"),
}
def payload():
    data=bytearray(END-CAVE); used=set()
    chunks={k:bytes.fromhex(v) for k,v in ENCODED.items()}
    chunks.update({SETUP_NAME:b"FMAdaptiveNativeDidSetup\0",
        FAILURE_NAME:b"FMAdaptiveNativeHandleFailure\0",
        0x509D20:b"FMX-ADAPTIVE-PLAYBACK-v1\0"})
    for offset,value in chunks.items():
        occupied=set(range(offset,offset+len(value)))
        if offset<CAVE or offset+len(value)>END or used&occupied:
            raise InteractionPatchError("Adaptive trampoline overlap")
        used|=occupied
        data[offset-CAVE:offset-CAVE+len(value)]=value
    if set(ENCODED)!=set(ASSEMBLY):raise InteractionPatchError("Adaptive encodings incomplete")
    return bytes(data)
def patch_plan(original):
    if len(original)!=ORIGINAL_BINARY_SIZE or sha256(original)!=ORIGINAL_BINARY_SHA256:
        raise InteractionPatchError("Original FreeMusic 4.2.7 executable SHA256 mismatch")
    _verify_cave(original,END-SHARED_CAVE)
    for offset,(length,digest) in CONTEXTS.items():
        if sha256(original[offset:offset+length])!=digest:
            raise InteractionPatchError(f"Adaptive host context mismatch at {offset:#x}")
    return [Change(SETUP_SITE,original[SETUP_SITE:SETUP_SITE+4],branch(SETUP_SITE,CAVE),
                   "associate real host setup with registered JS playback session"),
            Change(FAILURE_SITE,original[FAILURE_SITE:FAILURE_SITE+4],branch(FAILURE_SITE,0x509BC0),
                   "owned JS failure is handled before native retry/skip"),
            Change(CAVE,bytes(END-CAVE),payload(),"versioned adaptive playback host bridge")]
def patch_binary(original):
    result=apply_verified_plan(original,patch_plan(original))
    return result,{"original_sha256":sha256(original),"patched_sha256":sha256(result),
        "payload_sha256":sha256(payload()),"native_setup_rebind":True,
        "native_non_js_failure_preserved":True,"requires_resigning":True,
        "requires_extension":"FMAdaptivePlayback v1","actual_original_app_verified":False}

