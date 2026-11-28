"""Exercise the two native row values, matching Swift witnesses and all field offsets."""
import os
from pathlib import Path
import struct
import sys
import unittest

if sys.platform == "win32":
    import importlib.util
    tools = Path("D:/Program Files/Android/toolchain")
    spec = importlib.util.spec_from_file_location("unified_tools", tools / "config/environment.py")
    environment = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(environment)
    environment.setup_environment()
    deps = tools / "auxiliary/freemusic-folia/testdeps"
    if not deps.is_dir():
        raise RuntimeError("Restore the existing unified ARM64 test dependencies")
    sys.path.insert(0, str(deps))

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn import arm64_const as R
import download_order_patch as patch
import navigation_patch


def local_executable():
    location = os.environ.get("FREEMUSIC_ORIGINAL_EXECUTABLE")
    return Path(location) if location else Path(__file__).resolve().parent.parent / "private" / "429.bin"


class DownloadsFirst(unittest.TestCase):
    def test_projection_on_owned_result_and_missing_extension_fallback(self):
        for present in [False, True]:
            for site in patch.PROJECTION_SITES:
                with self.subTest(present=present, site=hex(site)):
                    vm = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
                    for page in [site & ~0xfff, patch.PROJECTION_CAVE & ~0xfff, 0x404000, 0x408000,
                                 0x10000, 0x20000, 0x30000, 0x31000]:
                        vm.mem_map(page, 0x1000)
                    vm.mem_write(site, patch._call(site, patch.PROJECTION_CAVE))
                    vm.mem_write(patch.PROJECTION_CAVE, patch.PROJECTION_CODE + patch.PROJECTION_SYMBOL)
                    vm.reg_write(R.UC_ARM64_REG_SP, 0x31800)
                    vm.reg_write(R.UC_ARM64_REG_X8, 0x30000)
                    vm.reg_write(R.UC_ARM64_REG_X1, 0x30200)
                    vm.reg_write(R.UC_ARM64_REG_X0, 0x30100)
                    vm.reg_write(R.UC_ARM64_REG_X2, 0x30300)
                    events = []
                    def emulate(cpu, pc, size, user):
                        if pc not in [patch.PUBLISHED_GET, 0x40821c, 0x10000]:
                            return
                        if pc == patch.PUBLISHED_GET:
                            events.append("get")
                            self.assertEqual(cpu.reg_read(R.UC_ARM64_REG_X8), 0x30000)
                            self.assertEqual(cpu.reg_read(R.UC_ARM64_REG_X0), 0x30100)
                            self.assertEqual(cpu.reg_read(R.UC_ARM64_REG_X1), 0x30200)
                            self.assertEqual(cpu.reg_read(R.UC_ARM64_REG_X2), 0x30300)
                            cpu.mem_write(0x30000, b"native!!")
                        elif pc == 0x40821c:
                            events.append("lookup")
                            name = cpu.reg_read(R.UC_ARM64_REG_X1)
                            self.assertEqual(bytes(cpu.mem_read(name, len(patch.PROJECTION_SYMBOL))), patch.PROJECTION_SYMBOL)
                            cpu.reg_write(R.UC_ARM64_REG_X0, 0x10000 if present else 0)
                        else:
                            events.append("sort")
                            self.assertEqual(cpu.reg_read(R.UC_ARM64_REG_X0), 0x30000)
                            self.assertEqual(cpu.reg_read(R.UC_ARM64_REG_X1), 0x30200)
                            self.assertEqual(bytes(cpu.mem_read(0x30000, 8)), b"native!!")
                            cpu.mem_write(0x30000, b"sorted!!")
                        # Both native and foreign calls may clobber their volatile registers.
                        cpu.reg_write(R.UC_ARM64_REG_X8, 0xab00)
                        cpu.reg_write(R.UC_ARM64_REG_X1, 0xab01)
                        cpu.reg_write(R.UC_ARM64_REG_PC, cpu.reg_read(R.UC_ARM64_REG_LR))
                    vm.hook_add(UC_HOOK_CODE, emulate)
                    vm.emu_start(site, site + 4, count=80)
                    self.assertEqual(vm.reg_read(R.UC_ARM64_REG_PC), site + 4)
                    self.assertEqual(vm.reg_read(R.UC_ARM64_REG_SP), 0x31800)
                    self.assertEqual(events, ["get", "lookup", "sort"] if present else ["get", "lookup"])
                    self.assertEqual(bytes(vm.mem_read(0x30000, 8)), b"sorted!!" if present else b"native!!")

    @unittest.skipUnless(local_executable().is_file(), "Original IPA remains on the owner's computer")
    def test_projection_is_limited_to_native_local_downloads_value_reads(self):
        original = local_executable().read_bytes()
        result, report = navigation_patch.patch_binary(original, original)
        self.assertEqual(report["download_tracks_order"], "display_only_han_pinyin_then_latin_then_other")
        for site in patch.PROJECTION_SITES:
            self.assertEqual(original[site:site + 4], patch._call(site, patch.PUBLISHED_GET))
            self.assertEqual(result[site:site + 4], patch._call(site, patch.PROJECTION_CAVE))
        # Label counts, select-all counts and set membership still use the unmodified read.
        for site in (0xc9438, 0xccf30, 0xcd5b8, 0xcd634):
            self.assertEqual(result[site:site + 4], original[site:site + 4])
        for at in (0xcab60, 0xd3590, patch.PROJECTION_CAVE):
            damaged = bytearray(original)
            damaged[at] ^= 1
            with self.assertRaises(ValueError):
                navigation_patch.patch_binary(bytes(damaged), original)

    def test_copy_witness_arguments_and_cleanup(self):
        dis = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        operations = []
        for pc, (_, new) in patch.BUILDER_WORDS.items():
            instruction, = dis.disasm(bytes.fromhex(new), pc)
            operations.append((instruction.mnemonic, instruction.op_str))
        self.assertEqual(operations, [
            ("mov", "x1, x19"), ("mov", "x2, x27"), ("blr", "x22"), ("mov", "x19, x0"),
            ("mov", "x1, x25"), ("mov", "x2, x26"), ("blr", "x21"),
            ("ldrsw", "x8, [x19, #0x40]"), ("ldrsw", "x8, [x19, #0x50]"),
            ("ldur", "x0, [x29, #-0xd8]"),
        ])

    def test_both_symbolic_references_retain_native_nominal_identity(self):
        for _, at, _ in patch.TYPE_RECORDS:
            for site, target in [(at, patch.DOWNLOADS), (at + 12, patch.RECENT)]:
                ref = patch._reference(site, target)
                self.assertEqual(ref[0], 2)
                self.assertEqual(site + 1 + struct.unpack_from("<i", ref, 1)[0], target)
        self.assertEqual(len({record[1] for record in patch.TYPE_RECORDS}), 11)

    @unittest.skipUnless(local_executable().is_file(), "Original IPA remains on the owner's computer")
    def test_native_list_types_can_change_only_as_a_complete_set(self):
        original = local_executable().read_bytes()
        patched, report = navigation_patch.patch_binary(original, original)
        self.assertEqual(report["library_first_row"], "native_local_downloads")
        self.assertEqual(report["library_second_row"], "native_recent_plays")
        expected_pairs = {at for _, at, _ in patch.TYPE_RECORDS}
        def paired_names(blob, first, second):
            sites = set()
            start, end = 0x442038, 0x4A5AF9  # __swift5_typeref in original 4.2.9
            while True:
                start = blob.find(b"\x02", start, end)
                if start < 0:
                    return sites
                if (blob[start:start + 5] == patch._reference(start, first)
                        and blob[start + 12:start + 17] == patch._reference(start + 12, second)):
                    sites.add(start)
                start += 1
        self.assertEqual(paired_names(original, patch.RECENT, patch.DOWNLOADS), expected_pairs)
        self.assertEqual(paired_names(patched, patch.DOWNLOADS, patch.RECENT), expected_pairs)
        self.assertFalse(paired_names(patched, patch.RECENT, patch.DOWNLOADS))
        for offset in (patch.BUILDER_START, next(iter(expected_pairs)) - 1):
            with self.subTest(offset=offset):
                incompatible = bytearray(original)
                incompatible[offset] ^= 1
                with self.assertRaises(ValueError):
                    navigation_patch.patch_binary(bytes(incompatible), original)

    @unittest.skipUnless(local_executable().is_file(), "Original IPA remains on the owner's computer")
    def test_actual_native_builder_copies_all_rows_and_destroys_correct_temporary_values(self):
        original = local_executable().read_bytes()
        patched, _ = navigation_patch.patch_binary(original, original)
        for image, order in [(original, ("recent", "downloads")), (patched, ("downloads", "recent"))]:
            for sizes in [(32, 112), (128, 48)]:
                with self.subTest(order=order, sizes=sizes):
                    self.run_native_builder(image, order, sizes)

    def run_native_builder(self, image, order, sizes):
        vm = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        vm.mem_map(0x100000, 0x100000)
        vm.mem_map(0x200000, 0x100000)
        vm.mem_map(0, 0x10000)
        vm.mem_write(0x109A74, image[0x109A74:patch.BUILDER_END])
        def reg(n):
            return getattr(R, f"UC_ARM64_REG_X{n}")
        def put(n, value):
            vm.reg_write(reg(n), value)
        def get(n):
            return vm.reg_read(reg(n))
        def storeq(addr, val):
            vm.mem_write(addr, struct.pack("<Q", val))
        frame, output, tuple_type = 0x238000, 0x240000, 0x244000
        get_tuple, copy3, copy4, destroy_other = 0x7720, 0xEE9C, 0x112EF0, 0x85E8
        source = {"recent": 0x250000, "downloads": 0x251000, "third": 0x252000, "fourth": 0x253000}
        dtype = {"recent": 0x260000, "downloads": 0x261000}
        copies = {0x270000: "recent", 0x270100: "downloads"}
        destroy = {0x270200: "recent", 0x270300: "downloads"}
        widths = dict(zip(("recent", "downloads"), sizes))
        widths.update(third=24, fourth=16)
        contents = {name: bytes([i + 1]) * widths[name] for i, name in enumerate(source)}
        for name, addr in source.items():
            vm.mem_write(addr, contents[name])
        offsets = (0, widths[order[0]], sum(sizes), sum(sizes) + widths["third"])
        for index in range(1, 4):
            vm.mem_write(tuple_type + 0x20 + index * 16, struct.pack("<i", offsets[index]))
        put(29, frame)
        for n, val in [(19, source["downloads"]), (20, 0x264000), (21, 0x270000), (22, 0x270100),
                       (24, source["fourth"]), (25, source["recent"]), (26, dtype["recent"]),
                       (27, dtype["downloads"]), (28, source["third"])]:
            put(n, val)
        for offset, value in [(0xb8, output), (0xd8, source["downloads"]), (0x98, 0x265000),
                              (0xa0, 0x266000), (0x88, 0x267000), (0x78, 0x268000),
                              (0x90, 0x269000), (0x80, 0x26A000)]:
            storeq(frame - offset, value)
        storeq(0x265008, 0x270300)
        storeq(0x266008, 0x270200)
        writes, releases = [], []
        def simulate(vm, pc, size, _context):
            if pc == patch.BUILDER_END:
                vm.emu_stop()
                return
            if pc == get_tuple:
                put(0, tuple_type)
            elif pc in copies:
                role = copies[pc]
                self.assertEqual((get(1), get(2)), (source[role], dtype[role]))
                writes.append((role, get(0)))
                vm.mem_write(get(0), bytes(vm.mem_read(get(1), widths[role])))
            elif pc in (copy3, copy4):
                role = "third" if pc == copy3 else "fourth"
                self.assertEqual(get(0), source[role])
                writes.append((role, get(1)))
                vm.mem_write(get(1), bytes(vm.mem_read(get(0), widths[role])))
            elif pc in destroy:
                role = destroy[pc]
                self.assertEqual(get(1), dtype[role])
                releases.append((role, get(0)))
            elif pc != destroy_other:
                return
            for n in range(1, 19):
                put(n, 0xDA0000 + n)
            vm.reg_write(R.UC_ARM64_REG_PC, get(30))
        vm.hook_add(UC_HOOK_CODE, simulate)
        vm.emu_start(0x109A74, patch.BUILDER_END, count=200)
        all_rows = order + ("third", "fourth")
        self.assertEqual(writes, list(zip(all_rows, (output + x for x in offsets))))
        self.assertEqual(releases, [("downloads", source["downloads"]), ("recent", source["recent"]),
                                    ("downloads", 0x269000), ("recent", 0x26A000)])
        expected = b"".join(contents[name] for name in all_rows)
        self.assertEqual(bytes(vm.mem_read(output, len(expected))), expected)


if __name__ == "__main__":
    unittest.main()
