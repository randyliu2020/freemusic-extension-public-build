"""Execute authored ARM64 final-save bridge; no original app code is bundled."""
import sys
if sys.platform == 'win32':
    import importlib.util
    from pathlib import Path
    spec=importlib.util.spec_from_file_location('_fm_tools','D:/Program Files/Android/toolchain/config/environment.py')
    environment=importlib.util.module_from_spec(spec);spec.loader.exec_module(environment);environment.setup_environment()
    dependencies=Path('D:/Program Files/Android/toolchain/auxiliary/freemusic-folia/testdeps')
    if not dependencies.is_dir():raise RuntimeError('Missing existing unified ARM64 analysis tools')
    sys.path.insert(0,str(dependencies))
import unittest
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
from keystone import Ks,KS_ARCH_ARM64,KS_MODE_LITTLE_ENDIAN
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn import arm64_const as R
import native_format_patch as p

class Machine:
    def __init__(self,exports=True,result=True,slide=0):
        self.base=p.BASE+slide
        self.vm=Uc(UC_ARCH_ARM64,UC_MODE_ARM);self.vm.mem_map(self.base,0x600000);self.vm.mem_map(0x200000,0x100000)
        self.stack=0x2d0000;self.frame=0x2e0000;self.set(29,self.frame);self.vm.reg_write(R.UC_ARM64_REG_SP,self.stack)
        self.vm.mem_write(self.base+p.CAVE,p.payload());self.exports=exports;self.result=result;self.calls=[];self.done=False
        self.function=self.base+0x5e0000;self.arguments=[0x210000,0xbadcafe,0x220000,0x230000,0x240000]
        for n,value in enumerate(self.arguments):self.set(n,value)
        for n in range(19,29):self.set(n,0x250000+n*0x100)
        self.saved=[self.get(n) for n in range(19,30)]
        for n in range(8,16):self.vm.reg_write(getattr(R,f'UC_ARM64_REG_D{n}'),0xAABB000+n)
        self.saved_fp=[self.vm.reg_read(getattr(R,f'UC_ARM64_REG_D{n}')) for n in range(8,16)]
        self.set(30,self.base+0x1234);self.vm.hook_add(UC_HOOK_CODE,self.hook)
    def set(self,n,value):self.vm.reg_write(getattr(R,f'UC_ARM64_REG_X{n}'),value)
    def get(self,n):return self.vm.reg_read(getattr(R,f'UC_ARM64_REG_X{n}'))
    def ret(self):self.vm.reg_write(R.UC_ARM64_REG_PC,self.get(30))
    def clobber(self):
        for n in range(1,19):self.set(n,0xDEAD000+n)
    def hook(self,vm,address,size,user):
        if address==self.base+p.CONTINUATION:self.done=True;vm.emu_stop();return
        if address==self.base+p.DYLSYM:
            assert self.get(0)==0xfffffffffffffffe
            assert bytes(vm.mem_read(self.get(1),64)).split(b'\0')[0]==b'FMDownloadNativeMove'
            assert vm.reg_read(R.UC_ARM64_REG_SP)%16==0
            self.clobber();self.set(0,self.function if self.exports else 0);self.ret()
        elif address==self.function:
            self.calls.append(('helper',[self.get(n) for n in range(4)]));assert vm.reg_read(R.UC_ARM64_REG_SP)%16==0
            if not self.result:vm.mem_write(self.get(3),(0xABCD).to_bytes(8,'little'))
            self.clobber();self.set(0,int(self.result));self.ret()
        elif address==self.base+p.ORIGINAL_MOVE:
            self.calls.append(('original',[self.get(n) for n in range(5)]));assert vm.reg_read(R.UC_ARM64_REG_SP)%16==0
            # The original objc stub supplies its own SEL; incoming x1 is opaque.
            if not self.result:vm.mem_write(self.get(4),(0xABCD).to_bytes(8,'little'))
            self.clobber();self.set(0,int(self.result));self.ret()
    def run(self):
        self.vm.emu_start(self.base+p.CAVE,self.base+0x600000,count=100)
        assert self.done

class NativeFormatPatchTests(unittest.TestCase):
    def test_authored_assembly_reassembles_and_decodes_completely(self):
        for offset,assembly in p.ASSEMBLY.items():
            encoded=bytes.fromhex(p.ENCODED[offset]);self.assertEqual(bytes(Ks(KS_ARCH_ARM64,KS_MODE_LITTLE_ENDIAN).asm(assembly,offset)[0]),encoded)
            self.assertEqual(sum(x.size for x in Cs(CS_ARCH_ARM64,CS_MODE_ARM).disasm(encoded,p.BASE+offset)),len(encoded))
    def test_helper_receives_real_objects_and_error_pointer_not_unknown_selector(self):
        for result in (False,True):
            machine=Machine(True,result);machine.run();a=machine.arguments
            self.assertEqual(machine.calls,[('helper',[a[0],a[2],a[3],a[4]])]);self.assertEqual(machine.get(0),int(result))
            self.assertEqual(int.from_bytes(machine.vm.mem_read(a[4],8),'little'),0 if result else 0xABCD)
    def test_missing_export_preserves_original_objc_move_arguments_and_result(self):
        for result in (False,True):
            machine=Machine(False,result);machine.run();self.assertEqual(machine.calls,[('original',machine.arguments)])
            self.assertEqual(machine.get(0),int(result))
    def test_both_paths_preserve_stack_frame_callee_registers_and_arc_live_objects(self):
        for exports in (False,True):
            machine=Machine(exports);machine.run()
            self.assertEqual([machine.get(n) for n in range(19,30)],machine.saved)
            self.assertEqual(machine.vm.reg_read(R.UC_ARM64_REG_SP),machine.stack);self.assertEqual(machine.get(30),p.BASE+0x1234)
            self.assertEqual([machine.vm.reg_read(getattr(R,f'UC_ARM64_REG_D{n}')) for n in range(8,16)],machine.saved_fp)
    def test_page_aligned_aslr_slide_keeps_resolved_export_and_continuation(self):
        for exports in (False,True):
            machine=Machine(exports,slide=0x2f000000);machine.run()
            self.assertEqual(machine.get(30),machine.base+0x1234)
            self.assertEqual(machine.get(0),1)
            self.assertEqual(machine.calls[0][0],"helper" if exports else "original")
    def test_allocations_are_separate_from_existing_features(self):
        import adaptive_playback_patch as previous
        self.assertGreaterEqual(p.CAVE,previous.END);self.assertLessEqual(p.END,0x50a000)
        self.assertEqual(len(p.payload()),p.END-p.CAVE)
    def test_unknown_or_corrupted_binaries_are_rejected(self):
        for binary in (bytes(128),bytes(p.ORIGINAL_BINARY_SIZE)):
            with self.assertRaises(p.InteractionPatchError):p.patch_plan(binary)

if __name__=='__main__':unittest.main()
