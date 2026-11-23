"""Run authored ARM64 trampolines with ABI/ownership sentinels, not the IPA."""

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

ROOT=Path(__file__).resolve().parent
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
from keystone import Ks,KS_ARCH_ARM64,KS_MODE_LITTLE_ENDIAN
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn import arm64_const as r
import playback_cache_patch as p


class Machine:
    def __init__(self, exports=True, suffix=True, bypass=False):
        self.vm=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
        self.vm.mem_map(p.BASE,0x600000)
        self.vm.mem_map(0x200000,0x100000)
        self.vm.mem_write(p.BASE+p.CAVE,p.payload())
        self.vm.mem_write(p.BASE+0x59acd8,struct.pack('<Q',0x180))
        self.stack=0x2F0000;self.frame=0x2E0000
        self.vm.reg_write(r.UC_ARM64_REG_SP,self.stack)
        self.vm.reg_write(r.UC_ARM64_REG_FP,self.frame)
        self.vm.reg_write(r.UC_ARM64_REG_LR,p.BASE+0x5F0000)
        for n in range(19,29):self.vm.reg_write(getattr(r,f'UC_ARM64_REG_X{n}'),0x210000+n*0x100)
        for n in range(8,16):self.vm.reg_write(getattr(r,f'UC_ARM64_REG_D{n}'),0xABC00000+n)
        self.exports=exports;self.suffix=suffix;self.bypass=bypass
        self.appended=[];self.releases=[];self.bridged=[];self.policy_calls=[];self.stopped=None
        self.target_string=None;self.suffix_object=0x240100;self.swift_object=0x240200
        self.suffix_function=p.BASE+0x5E0000;self.policy_function=p.BASE+0x5E0100
        self.vm.hook_add(UC_HOOK_CODE,self.hook)

    def read_cstring(self,address):
        return bytes(self.vm.mem_read(address,128)).split(b'\0')[0]
    def get(self,n):return self.vm.reg_read(getattr(r,f'UC_ARM64_REG_X{n}'))
    def set(self,n,value):self.vm.reg_write(getattr(r,f'UC_ARM64_REG_X{n}'),value)
    def ret(self):self.vm.reg_write(r.UC_ARM64_REG_PC,self.vm.reg_read(r.UC_ARM64_REG_LR))
    def hook(self,vm,address,size,user):
        if address in self.terminals:
            self.stopped=address;vm.emu_stop();return
        if address==p.BASE+p.DYLSYM:
            assert self.get(0)==0xFFFFFFFFFFFFFFFE
            name=self.read_cstring(self.get(1))
            assert name in (b'FMPlaybackCacheCopySuffix',b'FMPlaybackCacheShouldBypassURL')
            self.set(0,0 if not self.exports else self.suffix_function if name.endswith(b'CopySuffix') else self.policy_function)
            self.ret()
        elif address==self.suffix_function:
            self.set(0,self.suffix_object if self.suffix else 0);self.ret()
        elif address==p.BASE+p.STRING_FROM_NS:
            assert self.get(0)==self.suffix_object
            self.set(0,0xA100);self.set(1,self.swift_object);self.ret()
        elif address==p.BASE+p.STRING_APPEND:
            assert self.get(20)==self.target_string
            assert self.get(0)==0xA100 and self.get(1)==self.swift_object
            self.appended.append(self.get(20))
            # Authored sentinel represents the same opaque Swift String pair
            # produced by each original key builder; no Swift layout is guessed.
            vm.mem_write(self.target_string,struct.pack('<QQ',0xB100,0xB200));self.ret()
        elif address==p.BASE+p.STRING_RELEASE:
            self.releases.append(('swift',self.get(0)));self.ret()
        elif address==p.BASE+p.URL_TO_NS:
            pointer=self.get(20);obj=pointer+0x5000
            self.bridged.append((pointer,obj));self.set(0,obj);self.ret()
        elif address==p.BASE+p.OBJC_RELEASE:
            self.releases.append(('objc',self.get(0)));self.ret()
        elif address==self.policy_function:
            self.policy_calls.append((self.get(0),self.get(1)))
            self.set(0,int(self.bypass));self.ret()
    def start(self,offset,terminals):
        self.terminals={p.BASE+value for value in terminals}
        self.vm.emu_start(p.BASE+offset,p.BASE+0x600000,count=500)
        assert self.stopped is not None,'trampoline failed to return to original flow'
        return self.stopped-p.BASE
    def saved(self):
        regs=[getattr(r,f'UC_ARM64_REG_X{n}') for n in range(19,31)]
        regs += [r.UC_ARM64_REG_SP]+[getattr(r,f'UC_ARM64_REG_D{n}') for n in range(8,16)]
        return {reg:self.vm.reg_read(reg) for reg in regs}
    def check_saved(self,saved,changed=()):
        ignored={getattr(r,f'UC_ARM64_REG_X{n}') for n in changed}
        for reg,value in saved.items():
            if reg not in ignored:assert self.vm.reg_read(reg)==value,f'live register {reg} corrupted'


class PlaybackCachePatch(unittest.TestCase):
    def test_assembly_matches_production_payload_and_is_disjoint(self):
        cs=Cs(CS_ARCH_ARM64,CS_MODE_ARM)
        for offset,text in p.ASSEMBLY.items():
            encoded=bytes(Ks(KS_ARCH_ARM64,KS_MODE_LITTLE_ENDIAN).asm(text,addr=offset)[0])
            self.assertEqual(encoded,bytes.fromhex(p.ENCODED[offset]))
            self.assertEqual(sum(i.size for i in cs.disasm(encoded,offset)),len(encoded))
        data=p.payload()
        self.assertEqual(len(data),p.END-p.CAVE)
        self.assertIn(b'FMX-CACHE-GENERATION-v1\0',data)
        self.assertEqual(p.sha256(data),'2e7b3bd62a17e25e4e64113b2e907decaee412cadb143a3fab5cf608facafa4c')
        self.assertEqual(len(p.SITES),5)

    def test_three_native_key_builders_append_same_suffix_with_balanced_arc(self):
        for entry,slot,continuation,changed in [(0x509780,'stack',0x4b044,()),
                                                (0x5097A0,0x298,0x4de28,(23,)),
                                                (0x5097C0,0x3B0,0x57134,(21,))]:
            with self.subTest(entry=hex(entry)):
                m=Machine();m.target_string=m.stack+16 if slot=='stack' else m.get(19)+slot
                m.vm.mem_write(m.target_string,struct.pack('<QQ',0xA001,0xA002));saved=m.saved()
                self.assertEqual(m.start(entry,[continuation]),continuation)
                self.assertEqual(m.appended,[m.target_string]);m.check_saved(saved,changed)
                self.assertEqual(m.releases,[('swift',m.swift_object),('objc',m.suffix_object)])
                if slot=='stack':self.assertEqual((m.get(0),m.get(1)),(0xB100,0xB200))
                elif changed==(23,):self.assertEqual(m.get(23),0xB100)
                else:self.assertEqual(m.get(21),0xB100)

    def test_missing_export_or_unmatched_image_suffix_preserves_native_key(self):
        for exports,suffix in [(False,True),(True,False)]:
            for entry,slot,end,changed in [(0x509780,'stack',0x4b044,()),(0x5097A0,0x298,0x4de28,(23,)),(0x5097C0,0x3B0,0x57134,(21,))]:
                m=Machine(exports=exports,suffix=suffix);m.target_string=m.stack+16 if slot=='stack' else m.get(19)+slot
                original=struct.pack('<QQ',0xA001,0xA002);m.vm.mem_write(m.target_string,original);saved=m.saved()
                m.start(entry,[end]);m.check_saved(saved,changed)
                self.assertEqual(bytes(m.vm.mem_read(m.target_string,16)),original)
                self.assertEqual((m.appended,m.releases),([],[]))

    def test_automatic_mp3_falls_back_without_consuming_candidate_or_download_state(self):
        for exports,bypass,expected in [(True,True,0x73120),(True,False,0x731a4),(False,True,0x731a4)]:
            m=Machine(exports=exports,bypass=bypass)
            candidate=m.get(21);directory=m.get(22)+0x180
            m.vm.mem_write(m.get(20)+32,struct.pack('<Q',0xABC123))
            m.vm.mem_write(candidate,b'owned-optional-url')
            saved=m.saved()
            self.assertEqual(m.start(0x5098C0,[0x73120,0x731a4]),expected);m.check_saved(saved)
            self.assertEqual(bytes(m.vm.mem_read(candidate,18)),b'owned-optional-url')
            if exports:
                self.assertEqual(m.bridged,[(candidate,candidate+0x5000),(directory,directory+0x5000)])
                self.assertEqual(m.policy_calls,[(candidate+0x5000,directory+0x5000)])
                self.assertEqual(m.releases,[('objc',candidate+0x5000),('objc',directory+0x5000)])
            else:self.assertEqual(m.releases,[])
            if expected==0x731a4:self.assertEqual(m.get(8),0xABC123)
        # Native 73108 retains the old Optional URL until its existing 73154
        # tag check / 73180 destroy after alternate-format lookup. The branch
        # must not move or destroy it in the new trampoline above.

    def test_final_standard_candidate_policy_reuses_original_directory_exclusion(self):
        for exports,bypass,expected in [(True,True,0x4b3b8),(True,False,0x4b324),(False,True,0x4b324)]:
            m=Machine(exports=exports,bypass=bypass);candidate=0x260000;directory=m.get(19)+0x180
            m.vm.mem_write(m.frame-0x78,struct.pack('<Q',candidate));saved=m.saved();quality=m.get(27)
            self.assertEqual(m.start(0x509940,[0x4b3b8,0x4b324]),expected);m.check_saved(saved)
            if exports:self.assertEqual(m.policy_calls,[(candidate+0x5000,directory+0x5000)])
            if bypass and exports:self.assertEqual(m.releases[-1],('swift',quality))
            else:self.assertNotIn(('swift',quality),m.releases);self.assertEqual(m.get(2),0x7473)

    def test_payload_guard_is_synced_to_native_module(self):
        module=(ROOT/'FMPlaybackCache.m').read_text(encoding='utf-8')
        self.assertIn(p.sha256(p.payload()),module)
        self.assertIn('base+0x509780,0x3c0',module)
        self.assertIn('swift_context',module)
        self.assertIn('ns_consumed',module)

    def test_wrong_original_and_reapplying_are_rejected(self):
        with self.assertRaises(p.InteractionPatchError):p.patch_plan(b'authored unrelated binary')
        changes=[p.Change(0,b'original',b'changed!', 'authored fixture')]
        once=p.apply_verified_plan(b'original',changes)
        with self.assertRaises(p.InteractionPatchError):p.apply_verified_plan(once,changes)

    def test_local_original_only_authorized_ranges_change_and_compose(self):
        path=ROOT.parent/'private'/'429.bin'
        if not path.exists():self.skipTest('User original is deliberately kept local, never uploaded')
        original=path.read_bytes();patched,report=p.patch_binary(original);changes=p.patch_plan(original)
        self.assertEqual(len(patched),len(original));self.assertFalse(report['deletes_files'])
        allowed={i for change in changes for i in range(change.offset,change.offset+len(change.after))}
        self.assertTrue(all(a==b or i in allowed for i,(a,b) in enumerate(zip(original,patched))))
        with self.assertRaises(p.InteractionPatchError):p.patch_plan(patched)
        import interaction_patch,player_swipe_patch
        p.apply_verified_plan(original,changes+interaction_patch.patch_plan(original)+player_swipe_patch.patch_plan(original))

if __name__=='__main__':unittest.main()
