"""Move the existing Local Downloads NavigationLink above Recent Plays in 4.2.9.

The original List content has four children. The two leading NavigationLinks
have the same label type but different destination types and value witnesses.
Change both the structural tuple type and its only producer. Collection
identity, control actions, labels and their captured destinations stay native.
"""
from hashlib import sha256
import struct


# Indirect context-descriptor references used by the Swift runtime.
RECENT = 0x532A70
DOWNLOADS = 0x532C30

# (symbolic name descriptor, first destination reference, digest of entire name).
# Includes the leaf tuple, TupleView, List and outer modified View types.
TYPE_RECORDS = (
    (0x41D860, 0x45E5F8, "4bf70f9f263fb9ab"),
    (0x41D500, 0x45E881, "bd97419e618e625d"),
    (0x41D508, 0x45EB01, "6ed7a43c6a776f47"),
    (0x41D510, 0x45ED6C, "b8aabaa7775bd961"),
    (0x41D520, 0x45EF92, "57f34872d2ebf0f2"),
    (0x41D528, 0x45F186, "199f04cea7935cbe"),
    (0x41D530, 0x45F355, "f0fa05f7b02708a3"),
    (0x41D540, 0x45F50A, "66d30fc172e050ee"),
    (0x41D548, 0x45F63D, "032fbffe9180aaad"),
    (0x41D550, 0x45F75A, "03a4c56ee5c4bf05"),
    (0x41D7A0, 0x45FEF3, "f013ae8ae6b0514e"),
)

# The two original copy witnesses are called with their own source values
# and metadata. Put the tuple metadata in x19 so x21 is available for the
# second (Recent) copy. The original Downloads temporary is also in a frame
# slot, from which it is restored for its matching destructor.
BUILDER_WORDS = {
    0x109A7C: ("e10319aa", "e10313aa"),   # mov x1, x19  (Downloads)
    0x109A80: ("e2031aaa", "e2031baa"),   # mov x2, x27
    0x109A84: ("a0023fd6", "c0023fd6"),   # blr x22
    0x109A9C: ("f50300aa", "f30300aa"),   # mov x19, x0  (tuple metadata)
    0x109AA8: ("e10313aa", "e10319aa"),   # mov x1, x25  (Recent)
    0x109AAC: ("e2031baa", "e2031aaa"),   # mov x2, x26
    0x109AB0: ("c0023fd6", "a0023fd6"),   # blr x21
    0x109AB4: ("a84280b9", "684280b9"),   # ldrsw x8, [x19, #64]
    0x109AD4: ("a85280b9", "685280b9"),   # ldrsw x8, [x19, #80]
    0x109B18: ("e00313aa", "a08352f8"),   # ldur x0, [x29, #-216]
}

BUILDER_START = 0x109A04
BUILDER_END = 0x109B74
BUILDER_SHA256 = "aa9e1652965ee8d93e90aa9dbba8f0a4bac5c125d4ab824a21f0cd8ab9ece345"


def _reference(at: int, target: int) -> bytes:
    return b"\x02" + struct.pack("<i", target - (at + 1))


def _context_name(data: bytes, indirect: int) -> bytes:
    # Low 32 bits contain the image-relative target for these two chained rebases.
    descriptor = struct.unpack_from("<I", data, indirect)[0]
    name_ref = descriptor + 8
    name = name_ref + struct.unpack_from("<i", data, name_ref)[0]
    return data[name:name + 64].split(b"\0", 1)[0]


def changes(data: bytes) -> list[tuple[int, bytes, bytes, str]]:
    """Caller verifies the version and full original hash, then applies these ranges."""
    if (sha256(data[BUILDER_START:BUILDER_END]).hexdigest() != BUILDER_SHA256
            or _context_name(data, RECENT) != b"RecentPlaysView"
            or _context_name(data, DOWNLOADS) != b"LocalDownloadsView"):
        raise ValueError("Library List builder or native destinations changed")
    plan = []
    for descriptor, first, digest in TYPE_RECORDS:
        displacement, size = struct.unpack_from("<iI", data, descriptor)
        name = descriptor + displacement
        second = first + 12
        if (not name <= first < second + 5 <= name + size
                or sha256(data[name:name + size]).hexdigest()[:16] != digest):
            raise ValueError(f"Library structural type changed at {descriptor:#x}")
        for at, old, new in ((first, RECENT, DOWNLOADS), (second, DOWNLOADS, RECENT)):
            expected = _reference(at, old)
            if data[at:at + 5] != expected:
                raise ValueError(f"Unexpected Library destination at {at:#x}")
            plan.append((at + 1, expected[1:], _reference(at, new)[1:], "library_native_row_type"))
    for at, (old, new) in BUILDER_WORDS.items():
        before = bytes.fromhex(old)
        if data[at:at + 4] != before:
            raise ValueError(f"Library tuple initializer changed at {at:#x}")
        plan.append((at, before, bytes.fromhex(new), "library_native_row_value"))
    return plan
