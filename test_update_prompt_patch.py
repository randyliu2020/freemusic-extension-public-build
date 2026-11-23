"""Execute the checked-in presentation decision with authored callback arrays."""
import importlib.util
import struct
import sys
import unittest
from pathlib import Path

if sys.platform == "win32":
    toolroot = Path("D:/Program Files/Android/toolchain")
    spec = importlib.util.spec_from_file_location("fm_environment", toolroot/"config/environment.py")
    environment = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(environment)
    environment.setup_environment()
    sys.path.insert(0, str(toolroot/"auxiliary/freemusic-folia/testdeps"))

from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn import arm64_const as reg
import update_prompt_patch as patch


class UpdatePromptTests(unittest.TestCase):
    def test_checked_in_payload_matches_assembly(self):
        code, _ = Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN).asm(patch.ASSEMBLY, patch.CAVE)
        self.assertEqual(bytes(code), patch.PAYLOAD)

    def decision(self, *, force=False, count=1, native_thunk=True, native_context=True,
                 launch=True, captured=False, slide=0):
        base = 0x100000000 + slide
        vm = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        vm.mem_map(base, 0x560000)
        vm.mem_map(0x100000, 0x10000)
        result, checker, array, context = 0x101000, 0x102000, 0x103000, 0x104000
        def write_pointer(address, value):
            vm.mem_write(address, struct.pack("<Q", value))
        vm.mem_write(result+0x38, bytes([int(force)]))
        write_pointer(base+0x54CDA0, 0x60)
        write_pointer(checker+0x60, array)
        write_pointer(array+0x10, count)
        write_pointer(array+0x20, base+(0x31794 if native_thunk else 0x31798))
        write_pointer(array+0x28, context if native_context else 0)
        write_pointer(context+0x10, base+(0x7B9C if launch else 0x25ECD4))
        write_pointer(context+0x18, 0x105000 if captured else 0)
        vm.reg_write(reg.UC_ARM64_REG_X0, result)
        vm.reg_write(reg.UC_ARM64_REG_X20, checker)
        vm.mem_write(base+patch.CAVE, patch.PAYLOAD)
        vm.mem_write(base+patch.PRESENT_CALL, patch.branch(patch.PRESENT_CALL, patch.CAVE, link=True))

        outcome = []
        stops = {base+patch.PRESENTER: "present", base+patch.PRESENT_CALL+4: "quiet"}
        def stop(cpu, address, size, data):
            if address in stops:
                outcome.append(stops[address])
                vm.emu_stop()
        vm.hook_add(UC_HOOK_CODE, stop)
        vm.emu_start(base+patch.PRESENT_CALL, base+0x550000, count=40)
        self.assertEqual(vm.reg_read(reg.UC_ARM64_REG_X0), result)
        self.assertEqual(vm.reg_read(reg.UC_ARM64_REG_X20), checker)
        self.assertEqual(vm.reg_read(reg.UC_ARM64_REG_LR), base+patch.PRESENT_CALL+4)
        self.assertEqual(len(outcome), 1)
        return outcome[0]

    def test_launch_only_optional_sheet_is_quiet_with_or_without_slide(self):
        for slide in (0, 0x1246000):
            with self.subTest(slide=slide):
                self.assertEqual(self.decision(slide=slide), "quiet")

    def test_mandatory_or_manual_updates_still_present(self):
        for scenario in ({"force":True}, {"launch":False, "captured":True}, {"count":2}):
            with self.subTest(scenario=scenario):
                self.assertEqual(self.decision(**scenario), "present")

    def test_unknown_callbacks_retain_the_app_presentation(self):
        for scenario in ({"count":0}, {"native_thunk":False}, {"native_context":False}, {"captured":True}):
            with self.subTest(scenario=scenario):
                self.assertEqual(self.decision(**scenario), "present")


if __name__ == "__main__":
    unittest.main()
