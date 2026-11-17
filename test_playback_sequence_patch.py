"""Execute authored selection bridge. No original host instructions bundled."""
import sys
if sys.platform == 'win32':
    import importlib.util
    from pathlib import Path
    spec=importlib.util.spec_from_file_location('_fm_tools','D:/Program Files/Android/toolchain/config/environment.py')
    environment=importlib.util.module_from_spec(spec);spec.loader.exec_module(environment);environment.setup_environment()
    dependencies=Path('D:/Program Files/Android/toolchain/auxiliary/freemusic-folia/testdeps')
    if not dependencies.is_dir():raise RuntimeError('Missing existing unified ARM64 tools')
    sys.path.insert(0,str(dependencies))
import unittest
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
from keystone import Ks,KS_ARCH_ARM64,KS_MODE_LITTLE_ENDIAN
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn import arm64_const as R
import playback_sequence_patch as p

class Machine:
    def __init__(self,exports=True,slide=0):
        self.base=p.BASE+slide;self.exports=exports;self.calls=[];self.done=False
        self.vm=Uc(UC_ARCH_ARM64,UC_MODE_ARM);self.vm.mem_map(self.base,0x600000);self.vm.mem_map(0x200000,0x100000)
        self.vm.mem_write(self.base+p.CAVE,p.payload());self.stack=0x2d0000;self.function=self.base+0x5e0000
        self.vm.reg_write(R.UC_ARM64_REG_SP,self.stack)
        for n in range(31):self.set(n,0x210000+n*0x100)
        self.set(30,self.base+0x46b9c);self.original=[self.get(n) for n in range(31)]
        for n in range(8,16):self.vm.reg_write(getattr(R,f'UC_ARM64_REG_D{n}'),0xAABB000+n)
        self.saved_fp=[self.vm.reg_read(getattr(R,f'UC_ARM64_REG_D{n}')) for n in range(8,16)]
        self.vm.hook_add(UC_HOOK_CODE,self.hook)
    def set(self,n,value):self.vm.reg_write(getattr(R,f'UC_ARM64_REG_X{n}'),value)
    def get(self,n):return self.vm.reg_read(getattr(R,f'UC_ARM64_REG_X{n}'))
    def clobber(self):
        for n in range(19):self.set(n,0xDEAD000+n)
    def hook(self,vm,address,size,user):
        if address==self.base+p.CONTINUATION:self.done=True;vm.emu_stop();return
        if address==self.base+p.DYLSYM:
            assert self.get(0)==0xfffffffffffffffe
            assert bytes(vm.mem_read(self.get(1),64)).split(b'\0')[0]==b'FMPlaybackSequenceNativeSelection'
            assert vm.reg_read(R.UC_ARM64_REG_SP)%16==0
            self.clobber();self.set(0,self.function if self.exports else 0);vm.reg_write(R.UC_ARM64_REG_PC,self.get(30))
        elif address==self.function:
            assert vm.reg_read(R.UC_ARM64_REG_SP)%16==0
            self.calls.append(self.get(0));self.clobber();vm.reg_write(R.UC_ARM64_REG_PC,self.get(30))
    def run(self):
        self.vm.emu_start(self.base+p.CAVE,self.base+0x600000,count=100);assert self.done

class PlaybackSequencePatchTests(unittest.TestCase):
    def test_authored_assembly_reassembles_and_decodes(self):
        for offset,assembly in p.ASSEMBLY.items():
            encoded=bytes.fromhex(p.ENCODED[offset]);self.assertEqual(bytes(Ks(KS_ARCH_ARM64,KS_MODE_LITTLE_ENDIAN).asm(assembly,offset)[0]),encoded)
            self.assertEqual(sum(i.size for i in Cs(CS_ARCH_ARM64,CS_MODE_ARM).disasm(encoded,p.BASE+offset)),len(encoded))
    def test_notifies_exact_swift_owner_after_uuid_commit(self):
        machine=Machine();machine.run();self.assertEqual(machine.calls,[machine.original[20]])
    def test_missing_export_preserves_original_selection(self):
        machine=Machine(False);machine.run();self.assertEqual(machine.calls,[])
        self.assertEqual([machine.get(n) for n in range(9)],machine.original[:9])
    def test_inputs_swift_self_frame_and_return_survive_helper_clobber(self):
        for exports in (False,True):
            machine=Machine(exports);machine.run()
            self.assertEqual([machine.get(n) for n in range(9)],machine.original[:9])
            self.assertEqual([machine.get(n) for n in range(19,31)],machine.original[19:])
            self.assertEqual(machine.vm.reg_read(R.UC_ARM64_REG_SP),machine.stack-0x70)
            self.assertEqual([machine.vm.reg_read(getattr(R,f'UC_ARM64_REG_D{n}')) for n in range(8,16)],machine.saved_fp)
            self.assertEqual(int.from_bytes(machine.vm.mem_read(machine.stack-0x70,8),'little'),machine.saved_fp[1])
            self.assertEqual(int.from_bytes(machine.vm.mem_read(machine.stack-0x68,8),'little'),machine.saved_fp[0])
    def test_aslr_slide_keeps_symbol_and_continuation(self):
        for exports in (False,True):
            machine=Machine(exports,0x2f000000);machine.run()
            self.assertEqual(machine.get(30),machine.base+0x46b9c)
    def test_cave_does_not_overlap_v7_format_or_text_tail(self):
        import native_format_patch as previous
        self.assertGreaterEqual(p.CAVE,previous.END);self.assertLessEqual(p.END,0x50a000)
        self.assertEqual(len(p.payload()),p.END-p.CAVE)
    def test_unknown_builds_rejected(self):
        for data in (bytes(128),bytes(p.ORIGINAL_BINARY_SIZE)):
            with self.assertRaises(p.InteractionPatchError):p.patch_plan(data)

if __name__=='__main__':unittest.main()
