"""FreeMusic 4.2.9's native per-song menu label integration."""
from hashlib import sha256

from interaction_patch import CAVE as EXISTING_EXTENSION_START, _verify_cave

LABEL_ADAPTER = 0x50A180
LABEL_INITIALIZER = 0x40635C
LABEL_CALL = 0xBD950
PLAYER_LABEL = 0x1BA600
PLAYER_LABEL_ADAPTER = 0x50A220
# Each original Button initializer takes a nonescaping label closure. Supply
# the same row's Track to it while leaving its action and captured model intact.
ROW_LABELS = {
    0xBCED0: ("e30319aa", "song_actions_selected_track"),
    0x1DD0C0: ("e3031aaa", "playlist_song_actions_selected_track"),
    0xCBBA4: ("03430091", "download_context_selected_track"),
    0xCBF5C: ("e3031aaa", "download_row_selected_track"),
}
CONTEXTS = {
    0xBCE24: (0xBC, "a6eead24945e41b3f1d3f45f581c8e0ec17adc1db504c334a070a36e3c5d8a20"),
    0x1DD028: (0xA8, "023859af793264eff1084ea11bb9a2df4cbbf77650b09ce08f4e1308afd2b09c"),
    0xCBB18: (0x98, "6d9f5fc817d4e0be4bef6c89182acbcf452bf5eb7e1ecfaa5fa737c3cace1217"),
    0xCBEB8: (0xB4, "45015b1b3c071d131600be969d4d0c3776189d74ca65cfb038b1da44636d6fa3"),
    0xBD85C: (0x128, "5fe0cc4a894fbb61b693705af9e0f03d95922034de7a725f69c48501efdd31c9"),
    0xD5590: (4, "f15c4697f3e0e807722eb64a48eaccd3af4e263adc1d997678f8c8d3fe055418"),
    0xCBCC0: (4, "57d8c800f066e7a9b9a45f637835c2dc26720b16c81d08f910347c0791708102"),
    0x43F4D0: (28, "3be7f8dffbdec8f9808b5181b17552ecb540dc88b8fc7909871b52a544b39e1f"),
    0x43E7C4: (28, "8ffcff2a971e18f2d513c3adf4db985b09957ff55edd25e7fbcf61780870742c"),
    0x440C48: (28, "b5ee48d0c8441d4bdded2543483143e8bdbf3041ff6dd8ee0f5ef6d850a56ede"),
    # Always-present lyrics-translation label in PlayerMoreMenu, including its
    # one consumer. The following two contracts validate the host's Track copy
    # and writing of server + "_" + id to its public Now Playing metadata.
    0x1B9F48: (0x88, "f785e6fa6ea79c2c99253cfb85b6bc054fcc13739618b28bcd5a8ffc9bf3e3d2"),
    0x1BA600: (0x5C, "7317c2ebe589c449b88966aa6224084a44c146c64b83951ae2c4f314f41cebf1"),
    0x63754: (0x60, "74a89a41485601f8417477c9dc3c81dd1ab9f05111797be927bc8bf59bf3b509"),
    0x63D68: (0x98, "4b75eeb8455efa60bc1db81bd639f18defeef377635420d04a00f2154d85cdf7"),
}
# Preserve all five native Label initializer arguments, its indirect result
# and caller frame. The label saved its incoming Swift context at sp+0x30.
# The optional extension only annotates the initialized localized String; in
# every branch the native Label initializer retains normal Swift ownership.
ADAPTER_CODE = bytes.fromhex(
    "ff0301d1e00700a9e20f01a9e42302a9fd7b03a9e93b40f9290100b420008092"
    "a10100101ef8fb97a00000b4f00300aae00340f9e13b40f900023fd6e00740a9"
    "e20f41a9e42342a9fd7b43a9ff03019163f0fb17"
)
ADAPTER_NAME = b"FMXTagSongMenuTitle\0"
PLAYER_ADAPTER_NAME = b"FMXInitPlayerMenuLabel\0"
# Save the indirect result pointer and return address. If the new label
# builder is absent, re-enter the native initializer with its original frame.
PLAYER_ADAPTER_CODE = bytes.fromhex(
    "fd7bbea9fd030091e80b00f92000809241010010faf7fb97f00300aae80b40f9"
    "fd7bc2a8700000b4e00308aa00021fd6f44fbea9ecc0f217"
)


def changes(current, original):
    payload = ADAPTER_CODE + ADAPTER_NAME
    player_payload = PLAYER_ADAPTER_CODE + PLAYER_ADAPTER_NAME
    _verify_cave(original, PLAYER_LABEL_ADAPTER + len(player_payload) - EXISTING_EXTENSION_START)
    for offset, (width, expected) in CONTEXTS.items():
        if sha256(current[offset:offset + width]).hexdigest() != expected:
            raise ValueError(f"Unexpected 4.2.9 song menu at {offset:#x}")
    result = [(pc, bytes.fromhex("030080d2"), bytes.fromhex(op), label)
              for pc, (op, label) in ROW_LABELS.items()]
    result.append((LABEL_CALL, bytes.fromhex("83220d94"), bytes.fromhex("0c321194"), "song_menu_label"))
    result.append((LABEL_ADAPTER, bytes(len(payload)), payload, "song_menu_localized_label_adapter"))
    result.append((PLAYER_LABEL, bytes.fromhex("f44fbea9"), bytes.fromhex("083f0d14"), "player_more_lyrics_toggle_label"))
    result.append((PLAYER_LABEL_ADAPTER, bytes(len(player_payload)), player_payload, "player_more_clear_now_playing"))
    return result
