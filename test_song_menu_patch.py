"""Exercise the supported 4.2.9 song menu row bindings and original UI fallback."""
import struct
import unittest

from test_download_order_patch import local_executable, Uc, R, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
import song_menu_patch as menu


class SongMenuBindings(unittest.TestCase):
    def test_four_labels_use_their_captured_song(self):
        for site, (instruction, _) in menu.ROW_LABELS.items():
            cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
            cpu.mem_map(site & ~4095, 4096)
            cpu.mem_write(site, bytes.fromhex(instruction))
            for number in [24, 25, 26]:
                cpu.reg_write(getattr(R, f"UC_ARM64_REG_X{number}"), number * 1000)
            cpu.emu_start(site, site + 4)
            self.assertEqual(cpu.reg_read(R.UC_ARM64_REG_X3),
                             {0xBCED0: 25000, 0x1DD0C0: 26000, 0xCBBA4: 24016, 0xCBF5C: 26000}[site])

    def test_original_string_initializer_called_once_with_its_owned_arguments(self):
        for context, extension in [(0, False), (0x30080, False), (0x30080, True)]:
            with self.subTest(context=context, extension=extension):
                cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
                for page in [menu.LABEL_CALL & ~4095, menu.LABEL_ADAPTER & ~4095,
                             menu.LABEL_INITIALIZER & ~4095, 0x408000, 0x11000, 0x30000, 0x31000]:
                    cpu.mem_map(page, 4096)
                cpu.mem_write(menu.LABEL_CALL, bytes.fromhex("0c321194"))
                cpu.mem_write(menu.LABEL_ADAPTER,menu.ADAPTER_CODE + menu.ADAPTER_NAME)
                sp = 0x31800
                cpu.reg_write(R.UC_ARM64_REG_SP, sp)
                cpu.mem_write(sp + 0x30, struct.pack("<Q", context))
                args = {0:sp, 1:0x1101, 2:0x2202, 3:0x3303, 4:0x4404, 8:0x30440}
                for num, value in args.items():
                    cpu.reg_write(getattr(R, f"UC_ARM64_REG_X{num}"), value)
                events = []
                def handle(vm, addr, _, __):
                    if addr == 0x40821c:
                        events.append("resolve")
                        name = vm.reg_read(R.UC_ARM64_REG_X1)
                        self.assertEqual(bytes(vm.mem_read(name, len(menu.ADAPTER_NAME))), menu.ADAPTER_NAME)
                    elif addr == 0x11000:
                        events.append("tag")
                        self.assertEqual(vm.reg_read(R.UC_ARM64_REG_X0), sp)
                        self.assertEqual(vm.reg_read(R.UC_ARM64_REG_X1), context)
                    elif addr == menu.LABEL_INITIALIZER:
                        events.append("initialize")
                        self.assertEqual(vm.reg_read(R.UC_ARM64_REG_SP), sp)
                        self.assertEqual(vm.reg_read(R.UC_ARM64_REG_LR), menu.LABEL_CALL + 4)
                        for num, value in args.items():
                            self.assertEqual(vm.reg_read(getattr(R, f"UC_ARM64_REG_X{num}")), value)
                    else: return
                    target = vm.reg_read(R.UC_ARM64_REG_LR)
                    for num in range(18):
                        vm.reg_write(getattr(R, f"UC_ARM64_REG_X{num}"), 0x900 + num)
                    if addr == 0x40821c:
                        vm.reg_write(R.UC_ARM64_REG_X0, 0x11000 if extension else 0)
                    vm.reg_write(R.UC_ARM64_REG_PC, target)
                cpu.hook_add(UC_HOOK_CODE, handle)
                cpu.emu_start(menu.LABEL_CALL, menu.LABEL_CALL + 4, count=90)
                self.assertEqual(events, (["resolve"] if context else []) + (["tag"] if extension else []) + ["initialize"])

    def test_player_label_constructs_once_or_falls_back_to_native_label(self):
        for extension in [False, True]:
            with self.subTest(extension=extension):
                cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
                for page in [menu.PLAYER_LABEL & ~4095, menu.PLAYER_LABEL_ADAPTER & ~4095,
                             0x408000, 0x11000, 0x31000]:
                    cpu.mem_map(page, 4096)
                cpu.mem_write(menu.PLAYER_LABEL, bytes.fromhex("083f0d14"))
                cpu.mem_write(menu.PLAYER_LABEL_ADAPTER, menu.PLAYER_ADAPTER_CODE + menu.PLAYER_ADAPTER_NAME)
                sp, result, caller = 0x31800, 0x31100, 0x11100
                cpu.reg_write(R.UC_ARM64_REG_SP, sp)
                cpu.reg_write(R.UC_ARM64_REG_X8, result)
                cpu.reg_write(R.UC_ARM64_REG_X19, 19)
                cpu.reg_write(R.UC_ARM64_REG_X20, 20)
                cpu.reg_write(R.UC_ARM64_REG_X30, caller)
                events = []
                def inspect(vm, addr, _, __):
                    if addr == 0x40821c:
                        name = vm.reg_read(R.UC_ARM64_REG_X1)
                        self.assertEqual(bytes(vm.mem_read(name, len(menu.PLAYER_ADAPTER_NAME))), menu.PLAYER_ADAPTER_NAME)
                        events.append("resolve")
                        vm.reg_write(R.UC_ARM64_REG_X0, 0x11000 if extension else 0)
                        vm.reg_write(R.UC_ARM64_REG_X8, 0)
                        vm.reg_write(R.UC_ARM64_REG_PC, vm.reg_read(R.UC_ARM64_REG_LR))
                    elif addr in (menu.PLAYER_LABEL + 4, 0x11000):
                        is_extended = addr == 0x11000
                        self.assertEqual(vm.reg_read(R.UC_ARM64_REG_X8), result)
                        self.assertEqual(vm.reg_read(R.UC_ARM64_REG_SP), sp if is_extended else sp - 32)
                        self.assertEqual(vm.reg_read(R.UC_ARM64_REG_LR), caller)
                        if is_extended:
                            self.assertEqual(vm.reg_read(R.UC_ARM64_REG_X0), result)
                        else:
                            self.assertEqual(struct.unpack("<QQ", vm.mem_read(sp - 32, 16)), (20, 19))
                        events.append("extension" if is_extended else "original")
                        vm.emu_stop()
                cpu.hook_add(UC_HOOK_CODE, inspect)
                cpu.emu_start(menu.PLAYER_LABEL, caller, count=60)
                self.assertEqual(events, ["resolve", "extension" if extension else "original"])

    @unittest.skipUnless(local_executable().is_file(), "Original package is verified privately")
    def test_original_4381_model_and_menu_bindings(self):
        original = local_executable().read_bytes()
        changes = menu.changes(original, original)
        self.assertEqual(len(changes), 8)
        for offset, before, after, _ in changes:
            self.assertEqual(original[offset:offset + len(before)], before)
            self.assertEqual(len(before), len(after))
        for site in menu.ROW_LABELS:
            mutated = bytearray(original)
            mutated[site] ^= 1
            with self.assertRaises(ValueError):
                menu.changes(bytes(mutated), original)


if __name__ == "__main__":
    unittest.main()
