"""Execute authored missing-cover branches with ARM64 register/slot evidence."""
import sys
if sys.platform == 'win32':
    import importlib.util
    from pathlib import Path
    spec = importlib.util.spec_from_file_location('_fm_tools', 'D:/Program Files/Android/toolchain/config/environment.py')
    environment = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(environment)
    environment.setup_environment()
    dependencies = Path('D:/Program Files/Android/toolchain/auxiliary/freemusic-folia/testdeps')
    if not dependencies.is_dir():
        raise RuntimeError('Missing existing unified ARM64 analysis tools')
    sys.path.insert(0, str(dependencies))
import unittest
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn import arm64_const as R
import artwork_selection_patch as p

class Machine:
    def __init__(self, site, missing=True, exports=True, slide=0):
        self.base = p.BASE + slide
        self.vm = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        self.vm.mem_map(self.base, 0x600000)
        self.vm.mem_map(0x200000, 0x100000)
        self.site = site
        self.stack = 0x2d0000
        self.owner = 0x240000
        self.url_slot = self.owner + 0x180
        self.artwork_slot = self.owner + 0x160
        self.function = self.base + 0x5e0000
        self.exports = exports
        self.calls = []
        self.lookups = 0
        self.finished = None
        self.vm.mem_write(self.base+p.CAVE, p.payload())
        for branch_site, entry in [(p.NIL_SITE, p.CAVE), (p.EMPTY_SITE, p.CAVE+8)]:
            self.vm.mem_write(self.base+branch_site, p.branch(branch_site, entry))
        self.vm.mem_write(self.base+p.URL_IVAR, (0x180).to_bytes(8, 'little'))
        self.vm.mem_write(self.base+p.ARTWORK_IVAR, (0x160).to_bytes(8, 'little'))
        self.vm.mem_write(self.url_slot, bytes.fromhex('11111111111111112222222222222222'))
        self.vm.mem_write(self.artwork_slot, (0x250000).to_bytes(8, 'little'))
        self.before_url = bytes(self.vm.mem_read(self.url_slot, 16))
        self.before_artwork = bytes(self.vm.mem_read(self.artwork_slot, 8))
        for n in range(31):
            self.set(n, 0x260000+n*0x100)
        self.set(21, self.owner)
        self.set(26, 0 if missing and site == p.NIL_SITE else 0x1234)
        self.set(8, 0 if missing and site == p.EMPTY_SITE else 32)
        self.set(29, 0x2e0000)
        self.set(30, self.base+0x1234)
        self.vm.reg_write(R.UC_ARM64_REG_SP, self.stack)
        self.vm.reg_write(R.UC_ARM64_REG_NZCV, 0xa0000000)
        self.before_gp = [self.get(n) for n in range(31)]
        for n in range(8):
            self.vm.reg_write(getattr(R, f'UC_ARM64_REG_Q{n}'), 0xABCD0000000000000000000000000000+n)
        self.before_q = [self.vm.reg_read(getattr(R, f'UC_ARM64_REG_Q{n}')) for n in range(8)]
        for n in range(8, 16):
            self.vm.reg_write(getattr(R, f'UC_ARM64_REG_D{n}'), 0xAABB000+n)
        self.before_d = [self.vm.reg_read(getattr(R, f'UC_ARM64_REG_D{n}')) for n in range(8, 16)]
        self.vm.hook_add(UC_HOOK_CODE, self.hook)
    def set(self, n, value):
        self.vm.reg_write(getattr(R, f'UC_ARM64_REG_X{n}'), value)
    def get(self, n):
        return self.vm.reg_read(getattr(R, f'UC_ARM64_REG_X{n}'))
    def ret(self):
        self.vm.reg_write(R.UC_ARM64_REG_PC, self.get(30))
    def clobber(self):
        for n in range(19): self.set(n, 0xDEAD000+n)
        for n in range(8): self.vm.reg_write(getattr(R, f'UC_ARM64_REG_Q{n}'), 0xDEAD000+n)
        # The missing-path continuation makes an ordinary call before reading
        # flags; its incoming NZCV is not live. Normal branches preserve it.
        self.vm.reg_write(R.UC_ARM64_REG_NZCV, 0)
    def hook(self, vm, address, size, user):
        if address in [self.base+p.NIL_SITE+4, self.base+p.EMPTY_SITE+4, self.base+p.MISSING_CONTINUATION]:
            self.finished = address-self.base
            vm.emu_stop()
        elif address == self.base+p.DYLSYM:
            assert self.get(0) == 0xfffffffffffffffe
            assert bytes(vm.mem_read(self.get(1), 6)) == b'FMXAC\0'
            assert vm.reg_read(R.UC_ARM64_REG_SP) % 16 == 0
            self.lookups += 1
            self.clobber()
            self.set(0, self.function if self.exports else 0)
            self.ret()
        elif address == self.function:
            self.calls.append([self.get(0), self.get(1)])
            assert self.calls[-1] == [self.url_slot, self.artwork_slot]
            assert vm.reg_read(R.UC_ARM64_REG_SP) % 16 == 0
            vm.mem_write(self.url_slot, bytes(16))
            vm.mem_write(self.artwork_slot, bytes(8))
            self.clobber()
            self.set(0, 1)
            self.ret()
    def run(self):
        self.vm.emu_start(self.base+self.site, self.base+0x600000, count=160)
        assert self.finished is not None

class ArtworkSelectionPatchTests(unittest.TestCase):
    def test_authored_assembly_matches_bytes_and_decodes_without_gaps(self):
        for offset, assembly in p.ASSEMBLY.items():
            code = bytes.fromhex(p.ENCODED[offset])
            self.assertEqual(bytes(Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN).asm(assembly, offset)[0]), code)
            self.assertEqual(sum(i.size for i in Cs(CS_ARCH_ARM64, CS_MODE_ARM).disasm(code, p.BASE+offset)), len(code))
    def test_actual_nil_and_empty_branch_sites_clear_both_native_slots(self):
        for site in [p.NIL_SITE, p.EMPTY_SITE]:
            m = Machine(site)
            m.run()
            self.assertEqual(m.finished, p.MISSING_CONTINUATION)
            self.assertEqual(m.calls, [[m.url_slot, m.artwork_slot]])
            self.assertEqual(bytes(m.vm.mem_read(m.url_slot, 16)), bytes(16))
            self.assertEqual(bytes(m.vm.mem_read(m.artwork_slot, 8)), bytes(8))
    def test_normal_nonempty_paths_never_lookup_or_clear_and_resume_exact_next_instruction(self):
        for site in [p.NIL_SITE, p.EMPTY_SITE]:
            m = Machine(site, missing=False)
            m.run()
            self.assertEqual(m.finished, site+4)
            self.assertEqual((m.lookups, m.calls), (0, []))
            self.assertEqual(bytes(m.vm.mem_read(m.url_slot, 16)), m.before_url)
            self.assertEqual(bytes(m.vm.mem_read(m.artwork_slot, 8)), m.before_artwork)
            self.assertEqual(m.vm.reg_read(R.UC_ARM64_REG_NZCV), 0xa0000000)
    def test_missing_export_keeps_original_missing_path_and_owned_values(self):
        for site in [p.NIL_SITE, p.EMPTY_SITE]:
            m = Machine(site, exports=False)
            m.run()
            self.assertEqual(m.finished, p.MISSING_CONTINUATION)
            self.assertEqual((m.lookups, m.calls), (1, []))
            self.assertEqual(bytes(m.vm.mem_read(m.url_slot, 16)), m.before_url)
            self.assertEqual(bytes(m.vm.mem_read(m.artwork_slot, 8)), m.before_artwork)
    def test_calls_preserve_native_registers_stack_and_live_arc_references(self):
        for site in [p.NIL_SITE, p.EMPTY_SITE]:
            for exports in [False, True]:
                m = Machine(site, exports=exports)
                m.run()
                self.assertEqual([m.get(n) for n in range(31)], m.before_gp)
                self.assertEqual(m.vm.reg_read(R.UC_ARM64_REG_SP), m.stack)
                self.assertEqual([m.vm.reg_read(getattr(R, f'UC_ARM64_REG_Q{n}')) for n in range(8)], m.before_q)
                self.assertEqual([m.vm.reg_read(getattr(R, f'UC_ARM64_REG_D{n}')) for n in range(8, 16)], m.before_d)
    def test_page_aligned_aslr_keeps_field_addresses_export_and_branches(self):
        for site in [p.NIL_SITE, p.EMPTY_SITE]:
            m = Machine(site, slide=0x2f000000)
            m.run()
            self.assertEqual(m.calls, [[m.url_slot, m.artwork_slot]])
            self.assertEqual(m.finished, p.MISSING_CONTINUATION)
    def test_cave_allocation_is_disjoint_and_unknown_binaries_are_rejected(self):
        import playback_sequence_patch as previous
        self.assertGreaterEqual(p.CAVE, previous.END)
        self.assertEqual(p.END, 0x50a000)
        self.assertEqual(len(p.payload()), p.END-p.CAVE)
        for original in [bytes(128), bytes(p.ORIGINAL_BINARY_SIZE)]:
            with self.assertRaises(p.InteractionPatchError): p.patch_plan(original)

if __name__ == '__main__':
    unittest.main()
