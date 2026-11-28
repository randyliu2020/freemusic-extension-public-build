"""Execute real ARM64 predicate bytes; do not execute the original application."""

# Windows must use the user's unified D-drive tools; CI uses its declared runner dependencies.
import sys as _tool_sys
if _tool_sys.platform == 'win32':
    import importlib.util as _tool_importlib
    from pathlib import Path as _ToolPath
    _tool_spec = _tool_importlib.spec_from_file_location(
        '_unified_android_environment', 'D:/Program Files/Android/toolchain/config/environment.py')
    _tool_env = _tool_importlib.module_from_spec(_tool_spec)
    _tool_spec.loader.exec_module(_tool_env)
    _tool_env.setup_environment()
    _tool_deps = _ToolPath('D:/Program Files/Android/toolchain/auxiliary/freemusic-folia/testdeps')
    if not _tool_deps.is_dir():
        raise RuntimeError('Restore the existing test dependencies in the unified D-drive tool directory.')
    _tool_sys.path.insert(0, str(_tool_deps))

from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parent
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
        elif address in (p.BASE + p.NATIVE_DISMISS, p.BASE + 0x1abb9c):
            result.append(address == p.BASE + p.NATIVE_DISMISS)
            machine.emu_stop()
    vm.hook_add(UC_HOOK_CODE, hook)
    vm.emu_start(p.BASE + p.SITE, p.BASE + 0x600000, count=100)
    if len(result) != 1: raise AssertionError('Predicate did not reach a native terminal')
    for reg, value in saved.items():
        if vm.reg_read(reg) != value: raise AssertionError(f'Native capture/stack register {reg} changed')
    return result[0]


class PlayerSwipe(unittest.TestCase):
    def test_original_player_presentation_keeps_plain_and_zoom_content_ownership(self):
        ks = Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN)
        self.assertEqual(bytes(ks.asm(p.LAYOUT_ASSEMBLY, p.ZOOM_LAYOUT_CAVE)[0]), p.LAYOUT_CODE)
        for zoom in (False, True):
            for available in (False, True):
                with self.subTest(zoom=zoom, layout_helper=available):
                    base = p.BASE + 0x2000000
                    vm = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
                    vm.mem_map(base, 0x600000)
                    vm.mem_map(0x200000, 0x10000)
                    copy, attach = base + 0x54E000, base + 0x54E004
                    result, content, content_type, witness = 0x202000, 0x203000, 0x204000, 0xABCDEF
                    input_value, erased, annotated = 0xCCFF0010, 0xCCDDAA10, 0xDDEE0020
                    store = lambda addr, value: vm.mem_write(addr, struct.pack('<Q', value))
                    read = lambda addr: struct.unpack('<Q', vm.mem_read(addr, 8))[0]
                    store(content, input_value)
                    store(base + 0x535c80, witness)
                    vm.mem_write(base + p.ZOOM_LAYOUT_CAVE, p.LAYOUT_CODE + p.LAYOUT_SYMBOL)
                    site = p.ZOOM_LAYOUT_SITE if zoom else p.PLAIN_LAYOUT_SITE
                    cave = p.ZOOM_LAYOUT_CAVE if zoom else p.PLAIN_LAYOUT_CAVE
                    vm.mem_write(base + site, p.branch(site, cave))
                    state = {r.UC_ARM64_REG_X0: result, r.UC_ARM64_REG_X1: content, r.UC_ARM64_REG_X2: content_type,
                             r.UC_ARM64_REG_X8:copy, r.UC_ARM64_REG_X19: result, r.UC_ARM64_REG_X20: erased if zoom else content,
                             r.UC_ARM64_REG_SP:0x20e000, r.UC_ARM64_REG_FP:0x20e0a0}
                    for reg, value in state.items(): vm.reg_write(reg, value)
                    events = []
                    def hook(machine, address, size, data):
                        reg = machine.reg_read
                        x0 = reg(r.UC_ARM64_REG_X0)
                        if address == copy:
                            self.assertFalse(zoom)
                            self.assertEqual((x0,reg(r.UC_ARM64_REG_X1),reg(r.UC_ARM64_REG_X2)), (result,content,content_type))
                            store(x0, read(content))
                            events.append('copy')
                        elif address == base + 0x40821c:
                            self.assertEqual(bytes(machine.mem_read(reg(r.UC_ARM64_REG_X1),len(p.LAYOUT_SYMBOL))),p.LAYOUT_SYMBOL)
                            machine.reg_write(r.UC_ARM64_REG_X0, attach if available else 0)
                            events.append('lookup')
                        elif address == base + 0xed80:
                            self.assertEqual((x0,reg(r.UC_ARM64_REG_X1),reg(r.UC_ARM64_REG_X2),reg(r.UC_ARM64_REG_X3)),
                                             (base+0x54f6f8,base+0x54f6e0,base+0x419cd8,witness))
                            machine.reg_write(r.UC_ARM64_REG_X0,witness)
                        elif address == base + 0x406500:
                            self.assertEqual((x0,reg(r.UC_ARM64_REG_X1),reg(r.UC_ARM64_REG_X2)),(result,content_type,witness))
                            self.assertEqual(read(x0),input_value)
                            store(x0, 0)  # Generic AnyView.init consumes just the copied argument.
                            machine.reg_write(r.UC_ARM64_REG_X0,erased)
                            events.append('erase')
                        elif address == attach:
                            self.assertEqual((x0,read(x0)),(result,erased))
                            store(x0,annotated)
                            events.append('observe')
                        elif address in (base+0x9e240,base+0x9e030):
                            events.append('any-case' if address==base+0x9e240 else 'plain-case')
                            machine.emu_stop()
                            return
                        else:
                            return
                        machine.reg_write(r.UC_ARM64_REG_PC, reg(r.UC_ARM64_REG_LR))
                    vm.hook_add(UC_HOOK_CODE,hook)
                    vm.emu_start(base+site, base+0x600000, count=120)
                    expected = [] if zoom else ['copy']
                    expected.append('lookup')
                    if available:
                        if not zoom: expected.append('erase')
                        expected.append('observe')
                    expected.append('any-case' if zoom or available else 'plain-case')
                    self.assertEqual(events,expected)
                    self.assertEqual(read(content),input_value)
                    self.assertEqual(read(result),annotated if available else erased if zoom else input_value)
                    self.assertEqual(vm.reg_read(r.UC_ARM64_REG_SP),state[r.UC_ARM64_REG_SP])
                    if not zoom and available:
                        self.assertEqual(read(state[r.UC_ARM64_REG_FP]-0x78),state[r.UC_ARM64_REG_SP])

    def test_lyric_drag_calls_original_once_and_closes_only_matching_full_player(self):
        ks=Ks(KS_ARCH_ARM64,KS_MODE_LITTLE_ENDIAN)
        self.assertEqual(bytes(ks.asm(p.LYRIC_END_ASSEMBLY,p.LYRIC_END_CAVE)[0]),bytes.fromhex(p.LYRIC_END_HEX))
        self.assertEqual(bytes(ks.asm('adrp x2, 0x50b000; add x2, x2, #0xe00',p.LYRIC_END_SITE)[0]),p.LYRIC_END_REDIRECT)
        self.assertEqual(bytes(ks.asm('adrp x2, 0x50b000; add x2, x2, #0xe08', p.LYRIC_CHANGE_SITE)[0]), p.LYRIC_CHANGE_REDIRECT)
        for ended, accept, match, owner, available, style in [
            (False, True, True, True, True, 0), (True, False, True, True, True, 0),
            (True, True, True, True, True, 1), (True, True, False, True, True, 0),
            (True, True, True, False, True, 0), (True, True, True, True, False, 0)
        ]:
            with self.subTest(ended=ended, accept=accept, match=match, owner=owner, available=available):
                base=p.BASE+0x2000000
                vm=Uc(UC_ARCH_ARM64,UC_MODE_ARM);vm.mem_map(base,0x600000);vm.mem_map(0x200000,0x10000)
                for at in [0x1cd620,0x1c771c,p.FULL_PLAYER_DRAG]:
                    vm.mem_write(base+at,bytes.fromhex(p.CONTEXTS[at]))
                # Model the sibling callback entry. Its target is replaced below;
                # the local-original test checks its independent fingerprint.
                sibling = bytes.fromhex(p.CONTEXTS[0x1cd620])[:16] + p.branch(0x1cd61c, 0x1c771c)
                vm.mem_write(base+0x1cd60c, sibling)
                vm.mem_write(base+p.LYRIC_CHANGE_SITE,p.LYRIC_CHANGE_REDIRECT)
                vm.mem_write(base+p.LYRIC_END_SITE,p.LYRIC_END_REDIRECT)
                vm.mem_write(base+p.LYRIC_END_CAVE,bytes.fromhex(p.LYRIC_END_HEX)+p.LYRIC_POLICY_SYMBOL)
                gesture,lyric_context,player_context=0x201000,0x202000,0x203000
                metadata,witnesses,stop=0x204000,0x205000,base+0x550000
                vm.mem_write(metadata-8,struct.pack('<Q',witnesses))
                vm.mem_write(witnesses+0x50,b'\x0f')
                vm.mem_write(lyric_context+16+18,bytes([style]))
                vm.mem_write(lyric_context+16+24,struct.pack('<QQ',base+p.FULL_PLAYER_SEEK if match else 0,
                                                              player_context if owner else 0))
                initial={r.UC_ARM64_REG_SP:0x20f000,r.UC_ARM64_REG_X19:0x123,r.UC_ARM64_REG_X20:lyric_context,
                         r.UC_ARM64_REG_X21:0x456,r.UC_ARM64_REG_X22:0x654,r.UC_ARM64_REG_X29:0x789,r.UC_ARM64_REG_LR:stop}
                for reg,value in initial.items():vm.reg_write(reg,value)
                vm.reg_write(r.UC_ARM64_REG_X0,gesture)
                events=[]
                def hook(machine,address,size,user):
                    offset=address-base
                    if offset in (0x1c505c,0x1c1168): machine.reg_write(r.UC_ARM64_REG_X0,metadata)
                    elif offset in (p.LYRIC_NATIVE_ENDED, p.LYRIC_NATIVE_CHANGED):
                        events.append('scroll-end' if offset==p.LYRIC_NATIVE_ENDED else 'scroll-change')
                        self.assertEqual(machine.reg_read(r.UC_ARM64_REG_X0),gesture)
                        self.assertEqual(machine.reg_read(r.UC_ARM64_REG_X1),lyric_context+16)
                    elif offset==0x40821c:
                        events.append('lookup')
                        self.assertEqual(bytes(machine.mem_read(machine.reg_read(r.UC_ARM64_REG_X1),len(p.LYRIC_POLICY_SYMBOL))),p.LYRIC_POLICY_SYMBOL)
                        machine.reg_write(r.UC_ARM64_REG_X0,base+0x54e000 if available else 0)
                    elif offset==0x54e000:
                        events.append('lyric-policy')
                        self.assertEqual(machine.reg_read(r.UC_ARM64_REG_X0),player_context)
                        self.assertEqual(machine.reg_read(r.UC_ARM64_REG_X1),gesture)
                        self.assertEqual(machine.reg_read(r.UC_ARM64_REG_X2),int(ended))
                        self.assertEqual(machine.reg_read(r.UC_ARM64_REG_X3),style)
                        machine.reg_write(r.UC_ARM64_REG_X0,int(accept))
                    elif offset==0x1aba84:
                        events.append('full-player-gesture')
                        self.assertEqual(machine.reg_read(r.UC_ARM64_REG_X0),gesture)
                        self.assertEqual(machine.reg_read(r.UC_ARM64_REG_X1),player_context+16)
                    else:return
                    machine.reg_write(r.UC_ARM64_REG_PC,machine.reg_read(r.UC_ARM64_REG_LR))
                vm.hook_add(UC_HOOK_CODE,hook)
                vm.emu_start(base+(0x1cd620 if ended else 0x1cd60c),stop,count=200)
                self.assertEqual(vm.reg_read(r.UC_ARM64_REG_PC),stop)
                expected=['scroll-end' if ended else 'scroll-change']
                if match and owner:
                    expected.append('lookup')
                    if available: expected.append('lyric-policy')
                    if available and ended and accept: expected.append('full-player-gesture')
                self.assertEqual(events,expected)
                for reg,value in initial.items():self.assertEqual(vm.reg_read(reg),value)
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

    def test_local_original_exact_fingerprint_and_only_six_ranges(self):
        original=ROOT.parent/'private'/'429.bin'
        if not original.exists(): self.skipTest('Original remains local; never upload to CI')
        data=original.read_bytes(); output,report=p.patch_binary(data)
        self.assertEqual(len(output),len(data))
        changes=p.patch_plan(data)
        self.assertEqual(len(changes),6)
        allowed={i for c in changes for i in range(c.offset,c.offset+len(c.after))}
        self.assertTrue(all(a==b or i in allowed for i,(a,b) in enumerate(zip(data,output))))
        self.assertEqual(output[p.NATIVE_DISMISS:p.NATIVE_DISMISS+len(bytes.fromhex(p.NATIVE_DISMISS_HEX))],bytes.fromhex(p.NATIVE_DISMISS_HEX))
        self.assertTrue(report['original_downward_condition_preserved'])
        # Compose with the shipped lyric patch; neither cave overlaps the other.
        import interaction_patch
        combined=p.apply_verified_plan(data,interaction_patch.patch_plan(data)+changes)
        self.assertEqual(len(combined),len(data))


if __name__=='__main__': unittest.main()
