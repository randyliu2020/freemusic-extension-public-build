"""Execute only authored ARM64 bridges with caller/ARC/stack sentinels."""
from pathlib import Path
import struct
import unittest
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
from keystone import Ks,KS_ARCH_ARM64,KS_MODE_LITTLE_ENDIAN
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn import arm64_const as R
import adaptive_playback_patch as p

class Machine:
    def __init__(self,handled=True,exports=True):
        self.vm=Uc(UC_ARCH_ARM64,UC_MODE_ARM); self.vm.mem_map(p.BASE,0x600000)
        self.vm.mem_map(0x200000,0x100000); self.stack=0x2d0000; self.frame=0x2e0000
        self.vm.mem_write(p.BASE+p.CAVE,p.payload())
        self.vm.mem_write(p.BASE+0x54d6a0,struct.pack('<Q',0x100))
        self.vm.reg_write(R.UC_ARM64_REG_SP,self.stack); self.vm.reg_write(R.UC_ARM64_REG_FP,self.frame)
        for n in range(19,29):self.set(n,0x210000+n*0x1000)
        self.vm.mem_write(self.get(19)+0x100,struct.pack('<Q',0x260000))
        self.vm.mem_write(self.get(20)+0x100,struct.pack('<Q',0x260100))
        self.callee=[self.get(n) for n in range(19,29)]
        for n in range(8,16):self.vm.reg_write(getattr(R,f'UC_ARM64_REG_D{n}'),0xABC000+n)
        self.fp=[self.vm.reg_read(getattr(R,f'UC_ARM64_REG_D{n}')) for n in range(8,16)]
        self.handled=handled;self.exports=exports;self.calls=[];self.stopped=None
        self.function=p.BASE+0x5e0000;self.vm.hook_add(UC_HOOK_CODE,self.hook)
    def get(self,n):return self.vm.reg_read(getattr(R,f'UC_ARM64_REG_X{n}'))
    def set(self,n,v):self.vm.reg_write(getattr(R,f'UC_ARM64_REG_X{n}'),v)
    def ret(self):self.vm.reg_write(R.UC_ARM64_REG_PC,self.vm.reg_read(R.UC_ARM64_REG_LR))
    def clobber(self):
        for n in range(1,19):self.set(n,0xDAD000+n)
    def hook(self,vm,address,size,user):
        if address in self.terminals:self.stopped=address;vm.emu_stop();return
        if address==p.BASE+p.DYLSYM:
            self.assertName=bytes(vm.mem_read(self.get(1),64)).split(b'\0')[0]
            assert self.get(0)==0xFFFFFFFFFFFFFFFE
            self.clobber();self.set(0,self.function if self.exports else 0);self.ret()
        elif address==self.function:
            self.calls.append((self.assertName,self.get(0),self.get(1)))
            self.clobber();self.set(0,int(self.handled));self.ret()
    def run(self,start,terminals,lr):
        self.terminals={p.BASE+x for x in terminals};self.vm.reg_write(R.UC_ARM64_REG_LR,p.BASE+lr)
        self.vm.emu_start(p.BASE+start,p.BASE+0x600000,count=250)
        assert self.stopped is not None
    def check_callee(self):
        assert [self.get(n) for n in range(19,29)]==self.callee
        assert [self.vm.reg_read(getattr(R,f'UC_ARM64_REG_D{n}')) for n in range(8,16)]==self.fp
        assert self.vm.reg_read(R.UC_ARM64_REG_FP)==self.frame

class AdaptivePatchTests(unittest.TestCase):
    def test_reassemble_exact_and_all_instructions_valid(self):
        ks=Ks(KS_ARCH_ARM64,KS_MODE_LITTLE_ENDIAN);cs=Cs(CS_ARCH_ARM64,CS_MODE_ARM)
        for offset,asm in p.ASSEMBLY.items():
            encoded=bytes.fromhex(p.ENCODED[offset])
            self.assertEqual(bytes(ks.asm(asm,offset)[0]),encoded)
            self.assertEqual(sum(i.size for i in cs.disasm(encoded,p.BASE+offset)),len(encoded))
        self.assertEqual(len(p.payload()),p.END-p.CAVE)
    def test_setup_passes_original_owner_and_current_player(self):
        for exports in (False,True):
            m=Machine(exports=exports);m.run(p.CAVE,[p.SETUP_SITE+4],0x1234);m.check_callee()
            self.assertEqual(m.vm.reg_read(R.UC_ARM64_REG_SP),m.frame-0x50)
            self.assertEqual(m.vm.reg_read(R.UC_ARM64_REG_LR),p.BASE+0x1234)
            self.assertEqual(m.calls,[(b'FMAdaptiveNativeDidSetup',m.callee[0],0x260000)] if exports else [])
    def test_both_real_media_failure_callers_owned_and_unowned(self):
        for caller in (0x5a1b8,0x5aa7c):
            for exports,handled in ((True,True),(True,False),(False,False)):
                m=Machine(handled,exports);m.set(0,1);m.set(1,0);m.set(2,4)
                m.run(0x509bc0,[caller,p.FAILURE_SITE+4],caller);m.check_callee()
                self.assertEqual([m.get(n) for n in (0,1,2)],[1,0,4])
                self.assertEqual(m.stopped,p.BASE+(caller if exports and handled else p.FAILURE_SITE+4))
                self.assertEqual(m.vm.reg_read(R.UC_ARM64_REG_SP),m.stack if exports and handled else m.stack-0x60)
                if exports:self.assertEqual(m.calls[0],(b'FMAdaptiveNativeHandleFailure',m.callee[1],0x260100))
                else:self.assertEqual(m.calls,[])
    def test_other_failure_arguments_and_callers_never_call_extension(self):
        for args,caller in [((0,0,4),0x5a1b8),((1,0x1234,4),0x5aa7c),
                            ((1,0,3),0x5a1b8),((1,0,4),0x77ec8),((2,0,4),0x5a1b8)]:
            m=Machine();[m.set(n,v) for n,v in enumerate(args)]
            m.run(0x509bc0,[p.FAILURE_SITE+4],caller);m.check_callee()
            self.assertEqual(m.calls,[]);self.assertEqual([m.get(n) for n in (0,1,2)],list(args))
            self.assertEqual(m.vm.reg_read(R.UC_ARM64_REG_SP),m.stack-0x60)
    def test_namespace_does_not_overlap_other_features(self):
        import playback_cache_patch as cache,player_swipe_patch as swipe,navigation_patch as nav
        self.assertGreaterEqual(p.CAVE,cache.END)
        self.assertGreater(p.CAVE,swipe.CAVE+len(bytes.fromhex(swipe.TRAMPOLINE_HEX)))
        self.assertLessEqual(p.END,0x50a000)
    def test_rejects_unverified_input(self):
        with self.assertRaises(p.InteractionPatchError):p.patch_plan(bytes(128))
        with self.assertRaises(p.InteractionPatchError):p.patch_plan(bytes(p.ORIGINAL_BINARY_SIZE))
if __name__=='__main__':unittest.main()

