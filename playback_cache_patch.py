"""Version-locked playback cache generation and read-only disk selection.

Only independently authored trampoline bytes are shipped. Original executable
instructions are verified by digest and obtained from the local input; the IPA
is never embedded, executed, uploaded, or changed in place by this module.
"""
from __future__ import annotations
import hashlib
from interaction_patch import (
    ORIGINAL_BINARY_SHA256, ORIGINAL_BINARY_SIZE, BASE, Change,
    InteractionPatchError, apply_verified_plan, branch, sha256, _verify_cave,
    CAVE as SHARED_CAVE,
)

CAVE = 0x509780
END = 0x509B40
APPEND = 0x509800
URL_POLICY = 0x5099C0
SUFFIX_NAME = 0x509AA0
URL_POLICY_NAME = 0x509AE0
MARKER = 0x509B20
DYLSYM = 0x40821c
STRING_FROM_NS = 0x406b78
STRING_APPEND = 0x406ca4
STRING_RELEASE = 0x408e10
URL_TO_NS = 0x404634
OBJC_RELEASE = 0x408744

# Three independently emitted versions of the original server_id|quality key
# must agree: direct lookup/prefetch, preload scheduling, pending-preload prune.
SITES = {
    0x4b040: (0x509780, "5e45c6604d6fdb0e08f95212f70e2d8a28fc096a2a5806adaec39db05785a36c", "generation on common playback key"),
    0x4de24: (0x5097A0, "272d0ebc909f22ff066f38a5a2ce2ced6eba8d00497ffb38c5940fdb58ef5e72", "generation on pre-request preload key"),
    0x57130: (0x5097C0, "563012664499613c7c35aa6cc654b1ed63b915eaa8f97ab48f7d4e92d15c6700", "generation on pending-preload keep set"),
    0x731a0: (0x5098C0, "9159037c89843bdd62b43081e89bd1f762eb0601da9cf161e9e6d0ad7b32e91a", "automatic MP3 cannot hide an existing downloaded alternate format"),
    0x4b320: (0x509940, "dbc0f4b1ffe0c9905a6f692d35ebf77a4ac043c60e47726ed030d552d0662d2f", "affected automatic disk cache uses original directory exclusion"),
}

ASSEMBLY = {
0x509780: """
stp x29, x30, [sp, #-16]!
add x0, sp, #32
bl 0x509800
ldp x29, x30, [sp], #16
ldp x0, x1, [sp, #16]
b 0x4b044
""",
0x5097A0: """
stp x29, x30, [sp, #-16]!
add x0, x19, #0x298
bl 0x509800
ldp x29, x30, [sp], #16
ldr x23, [x19, #0x298]
b 0x4de28
""",
0x5097C0: """
stp x29, x30, [sp, #-16]!
add x0, x19, #0x3b0
bl 0x509800
ldp x29, x30, [sp], #16
ldr x21, [x19, #0x3b0]
b 0x57134
""",
APPEND: """
stp x29, x30, [sp, #-48]!
stp x19, x20, [sp, #16]
stp x21, x22, [sp, #32]
mov x19, x0
mov x0, #-2
adrp x1, 0x509000
add x1, x1, #0xaa0
bl 0x40821c
cbz x0, done
blr x0
cbz x0, done
mov x21, x0
bl 0x406b78
mov x22, x1
mov x20, x19
bl 0x406ca4
mov x0, x22
bl 0x408e10
mov x0, x21
bl 0x408744
done:
ldp x21, x22, [sp, #32]
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp], #48
ret
""",
0x5098C0: """
stp x29, x30, [sp, #-16]!
mov x0, x21
adrp x8, 0x59a000
ldr x8, [x8, #0xcd8]
add x1, x22, x8
bl 0x5099c0
cbnz w0, alternate
ldp x29, x30, [sp], #16
ldr x8, [x20, #32]
b 0x731a4
alternate:
ldp x29, x30, [sp], #16
b 0x73120
""",
0x509940: """
stp x29, x30, [sp, #-16]!
ldur x0, [x29, #-0x78]
adrp x8, 0x59a000
ldr x8, [x8, #0xcd8]
add x1, x19, x8
bl 0x5099c0
cbnz w0, exclude
ldp x29, x30, [sp], #16
mov x2, #0x7473
b 0x4b324
exclude:
mov x0, x27
bl 0x408e10
ldp x29, x30, [sp], #16
b 0x4b3b8
""",
URL_POLICY: """
stp x29, x30, [sp, #-64]!
stp x19, x20, [sp, #16]
stp x21, x22, [sp, #32]
stp x23, x24, [sp, #48]
mov x19, x0
mov x21, x1
mov x0, #-2
adrp x1, 0x509000
add x1, x1, #0xae0
bl 0x40821c
cbz x0, done
mov x22, x0
mov x20, x19
bl 0x404634
mov x23, x0
mov x20, x21
bl 0x404634
mov x24, x0
mov x0, x23
mov x1, x24
blr x22
mov w19, w0
mov x0, x23
bl 0x408744
mov x0, x24
bl 0x408744
mov w0, w19
done:
ldp x23, x24, [sp, #48]
ldp x21, x22, [sp, #32]
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp], #64
ret
""",
}

# Generated from ASSEMBLY and independently reassembled/emulated by tests.
ENCODED = {
    0x509780: 'fd7bbfa9e08300911e000094fd7bc1a8e00741a92c06ed17',
    0x5097a0: 'fd7bbfa960620a9116000094fd7bc1a8774e41f99d11ed17',
    0x5097c0: 'fd7bbfa960c20e910e000094fd7bc1a875da41f95836ed17',
    0x509800: 'fd7bbda9f35301a9f55b02a9f30300aa200080920100009021802a9180fafb97800100b400003fd6400100b4f50300aad2f4fb97f60301aaf40313aa1af5fb97e00316aa73fdfb97e00315aabefbfb97f55b42a9f35341a9fd7bc3a8c0035fd6',
    0x5098c0: 'fd7bbfa9e00315aa880400b0086d46f9c102088b3b00009480000035fd7bc1a8881240f930a6ed17fd7bc1a80da6ed17',
    0x509940: 'fd7bbfa9a08358f8880400b0086d46f96102088b1b00009480000035fd7bc1a8628e8ed27006ed17e0031baa29fdfb97fd7bc1a89106ed17',
    0x5099c0: 'fd7bbca9f35301a9f55b02a9f76303a9f30300aaf50301aa200080920100009021802b910efafb97200200b4f60300aaf40313aa10ebfb97f70300aaf40315aa0debfb97f80300aae00317aae10318aac0023fd6f303002ae00317aa4afbfb97e00318aa48fbfb97e003132af76343a9f55b42a9f35341a9fd7bc4a8c0035fd6',
}

def payload() -> bytes:
    result = bytearray(END-CAVE)
    used: set[int] = set()
    chunks = {offset: bytes.fromhex(value) for offset, value in ENCODED.items()}
    chunks.update({SUFFIX_NAME:b"FMPlaybackCacheCopySuffix\0", URL_POLICY_NAME:b"FMPlaybackCacheShouldBypassURL\0", MARKER:b"FMX-CACHE-GENERATION-v1\0"})
    for offset, value in chunks.items():
        occupied = set(range(offset,offset+len(value)))
        if offset<CAVE or offset+len(value)>END or used&occupied:
            raise InteractionPatchError("Playback cache trampoline allocation overlaps")
        used |= occupied
        result[offset-CAVE:offset-CAVE+len(value)] = value
    if set(ENCODED) != set(ASSEMBLY):
        raise InteractionPatchError("Playback cache encodings incomplete")
    return bytes(result)

def patch_plan(original:bytes) -> list[Change]:
    if len(original)!=ORIGINAL_BINARY_SIZE or sha256(original)!=ORIGINAL_BINARY_SHA256:
        raise InteractionPatchError("Original FreeMusic 4.2.9 executable SHA256 mismatch")
    for offset, expected in [(307244, 'fa91bc242dbf00d77ad4059281a3724cbf0ae72984de5bbbf1ad1f18c858a2fe'), (318992, '51ff2a71267d9cecf8ac515bd4bee03049b96d6eb56f86ae8cf755a297fe2b12'), (356636, 'fe8e0aba1db731e939879dfc27496bdf4e9529202f049c6246911ed7cd4119d3'), (471436, 'da88272243cbda9ded88fa697d345e29d2f121611032227f3ccdba4e340a9846'), (307980, '26d67d9fd7f10e0cf54461205c3454015c7d35c3c04e1df66c7490251ae5cba3')]:
        if sha256(original[offset:offset+40]) != expected:
            raise InteractionPatchError("Unsupported 4381 cache site context")
    data=payload()
    _verify_cave(original,END-SHARED_CAVE)
    changes=[]
    for site,(target,digest,reason) in SITES.items():
        before=original[site:site+4]
        if sha256(before)!=digest:raise InteractionPatchError(f"Playback cache context mismatch at {site:#x}")
        changes.append(Change(site,before,branch(site,target),reason))
    changes.append(Change(CAVE,bytes(len(data)),data,"versioned cache generation/read-only automatic-cache policy"))
    return changes

def patch_binary(original:bytes):
    changes=patch_plan(original)
    result=apply_verified_plan(original,changes)
    return result,{"original_sha256":sha256(original),"patched_sha256":sha256(result),
                   "key_builders":3,"disk_selection_gates":2,"deletes_files":False,
                   "requires_extension":"FMPlaybackCache v1","requires_resigning":True,
                   "payload_sha256":sha256(payload())}
