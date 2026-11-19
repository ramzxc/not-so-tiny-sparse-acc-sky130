"""Compiler boundaries: preserve unknown addresses, phases, fences and external IO."""
import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from compact_sram import compact_sram
class CompactCompiler(unittest.TestCase):
    def test_fold_and_fences(self):
        words=[0x8000,0x2300,0x3000,0x4400,0xffff,0x8400,0x23fe,0x4400,0xffff,0x6800,0xffff,0x9000,0x2000,0x5400]
        self.assertEqual(compact_sram(words),[0xe180,0xffff,0xe3ff,0xffff,0x6800,0xffff,0xf400])
    def test_unknown_after_micro(self):
        words=[0x2000,0x3000,0xb403,0x8000,0x2200,0x4400]
        self.assertEqual(compact_sram(words),words)
        words[-1:-1]=[0x3000]
        self.assertEqual(compact_sram(words),[0x2000,0x3000,0xb403,0xe100])
    def test_phase_and_external_boundaries(self):
        for words in ([0x8000,0x2000,0x3001,0x4000], # external access
                      [0x8000,0x2001,0x3000,0x4400], # invalid alignment must not be hidden
                      [0x8000,0x2400,0x3000,0x4400], # invalid SRAM address
                      [0x8000,0x2000,0x3000,0xffff,0x4400], # fence interrupts pattern
                      [0x18000,0x22000,0x23000,0x24400]): # phase boundary
            self.assertEqual(compact_sram(words),words)
    def test_postincrement(self):
        words=[0x2000,0x3000,0x4500,0x8000,0x4400]
        self.assertEqual(compact_sram(words),[0x2000,0x3000,0x4500,0xe001])
if __name__=='__main__':unittest.main()
