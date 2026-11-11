"""Compare narrow arithmetic against a saved pre-change tpu_pkg.sv.

Usage: python3 test/check_fp16_narrow.py --reference PATH --output DIR
Requires Verilator and a C++ compiler; no cocotb dependency.
"""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reference', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
reference = args.reference.read_text().replace('package tpu_pkg;', 'package fp16_reference_pkg;')
(out / 'fp16_reference_pkg.sv').write_text(reference)
with (out / 'test_build.log').open('w') as log:
    subprocess.run([
        'verilator', '--binary', '-j', '4', '-Wno-fatal',
        '--top-module', 'tb_fp16_narrow', '--Mdir', str(out / 'obj_test'),
        str(root / 'src/tpu_pkg.sv'), str(out / 'fp16_reference_pkg.sv'),
        str(root / 'test/tb_fp16_narrow.sv'),
    ], stdout=log, stderr=subprocess.STDOUT, check=True)
with (out / 'test_result.log').open('w') as log:
    subprocess.run([str(out / 'obj_test/Vtb_fp16_narrow')],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
print((out / 'test_result.log').read_text())
