"""Execute real ARM64 predicate bytes; do not execute the original application."""
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parent
for directory in (ROOT.parent / "freemusic_analysis" / "protocoldeps", ROOT.parent / "freemusic_analysis" / "interactiondeps"):
    if directory.exists(): sys.path.insert(0, str(directory))
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn import arm64_const as r
import player_swipe_patch as p


def bits(value): return struct.unpack('<Q', struct.pack('<d', value))[0]


def execute(dx, dy, patched):
    vm = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    vm.mem_map(p.BASE, 0x600000)
    vm.mem_write(p.BASE + p.SITE, bytes.fromhex(p.ORIGINAL_PREDICATE_HEX))
    vm.mem_write(p.BASE + p.CAVE, bytes.fromhex(p.TRAMPOLINE_HEX))
    if patched: vm.mem_write(p.BASE + p.SITE, p.branch(p.SITE, p.CAVE))
    saved = {getattr(r, f'UC_ARM64_REG_X{i}'): 0x10000+i for i in range(19, 29)}
    saved[r.UC_ARM64_REG_FP] = 0x20000
    saved[r.UC_ARM64_REG_SP] = 0x30000
    # No allocation, ARC, borrowed-value copy, or change to native capture.
    saved[r.UC_ARM64_REG_D9] = bits(7.125)
    for reg, value in saved.items(): vm.reg_write(reg, value)
    result = []
    def hook(machine, address, size, user):
        if address == p.BASE + p.TRANSLATION_GETTER:
            machine.reg_write(r.UC_ARM64_REG_D0, bits(dx))
            machine.reg_write(r.UC_ARM64_REG_D1, bits(dy))
            machine.reg_write(r.UC_ARM64_REG_PC, machine.reg_read(r.UC_ARM64_REG_LR))
        elif address in (p.BASE + p.NATIVE_DISMISS, p.BASE + 0x1ABCF4):
            result.append(address == p.BASE + p.NATIVE_DISMISS)
            machine.emu_stop()
    vm.hook_add(UC_HOOK_CODE, hook)
    vm.emu_start(p.BASE + p.SITE, p.BASE + 0x600000, count=100)
    if len(result) != 1: raise AssertionError('Predicate did not reach a native terminal')
    for reg, value in saved.items():
        if vm.reg_read(reg) != value: raise AssertionError(f'Native capture/stack register {reg} changed')
    return result[0]


class PlayerSwipe(unittest.TestCase):
    def test_encoded_instructions_and_all_branch_destinations(self):
        assembled, _ = Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN).asm(p.TRAMPOLINE_ASSEMBLY, addr=p.CAVE)
        self.assertEqual(bytes(assembled), bytes.fromhex(p.TRAMPOLINE_HEX))
        cs = Cs(CS_ARCH_ARM64, CS_MODE_ARM); cs.detail = True
        instructions = list(cs.disasm(bytes(assembled), p.CAVE))
        self.assertEqual(len(instructions), 13)
        targets = [i.operands[0].imm for i in instructions if i.mnemonic.startswith('b')]
        self.assertEqual(targets, [p.TRANSLATION_GETTER, p.CAVE+48, p.CAVE+48, p.NATIVE_DISMISS, p.ORIGINAL_CONDITION])

    def test_left_threshold_direction_and_diagonal_boundaries(self):
        for dx, dy, expected in [(-81,0,True),(-80,0,False),(-79.99,0,False),
                                 (120,0,False),(0,0,False),(-120,80,False),
                                 (-121,80,True),(-120,-80,False),(-121,-80,True),
                                 (-90,-150,False),(-90,150,True)]:
            with self.subTest(dx=dx,dy=dy): self.assertEqual(execute(dx,dy,True),expected)

    def test_all_original_downward_and_nonleft_cases_unchanged(self):
        for dx in [-200,-80,-5,0,5,80,200]:
            for dy in [-200,-81,-80,0,79.99,80,80.01,81,200]:
                added = dx < -80 and -dx > 1.5*abs(dy)
                with self.subTest(dx=dx,dy=dy):
                    self.assertEqual(execute(dx,dy,True), execute(dx,dy,False) or added)

    def test_nan_cannot_trigger_added_close(self):
        for dx,dy in [(float('nan'),0),(-100,float('nan')),(float('nan'),float('nan'))]:
            self.assertFalse(execute(dx,dy,True))

    def test_wrong_binary_refused(self):
        with self.assertRaises(p.InteractionPatchError): p.patch_plan(b'other app')

    def test_disjoint_composition_and_already_patched_refusal(self):
        a=p.Change(4,b'AAAA',b'BBBB','fixture'); b=p.Change(8,b'CCCC',b'DDDD','fixture')
        value=p.apply_verified_plan(b'0000AAAACCCC',[a,b])
        self.assertEqual(value,b'0000BBBBDDDD')
        with self.assertRaises(p.InteractionPatchError): p.apply_verified_plan(value,[a])

    def test_local_original_exact_fingerprint_and_only_two_ranges(self):
        original=ROOT.parent/'freemusic_analysis'/'main.bin'
        if not original.exists(): self.skipTest('Original remains local; never upload to CI')
        data=original.read_bytes(); output,report=p.patch_binary(data)
        self.assertEqual(len(output),len(data))
        changes=p.patch_plan(data)
        self.assertEqual(len(changes),2)
        allowed={i for c in changes for i in range(c.offset,c.offset+len(c.after))}
        self.assertTrue(all(a==b or i in allowed for i,(a,b) in enumerate(zip(data,output))))
        self.assertEqual(output[p.NATIVE_DISMISS:p.NATIVE_DISMISS+len(bytes.fromhex(p.NATIVE_DISMISS_HEX))],bytes.fromhex(p.NATIVE_DISMISS_HEX))
        self.assertTrue(report['original_downward_condition_preserved'])
        # Compose with the shipped lyric patch; neither cave overlaps the other.
        import interaction_patch
        combined=p.apply_verified_plan(data,interaction_patch.patch_plan(data)+changes)
        self.assertEqual(len(combined),len(data))


if __name__=='__main__': unittest.main()
