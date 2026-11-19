#!/usr/bin/env python3
"""Isolate the simulator reference, its explicit hard-activation variant and data."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
SIM=Path('/docker/projects/egru/sim')
EIGEN=Path('/home/ramzxc/.conda/envs/egru-sim/include/eigen3')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output',type=Path,default=Path('/tmp/acc-full-egru'))
    args=ap.parse_args(); out=args.output; out.mkdir(parents=True,exist_ok=True)
    spec=importlib.util.spec_from_file_location('egru_parser',SIM/'python/parser.py')
    parser=importlib.util.module_from_spec(spec); spec.loader.exec_module(parser)
    variant=out/'hard_source'
    for folder in ('lib/common','lib/model'):
        shutil.copytree(SIM/folder,variant/folder,dirs_exist_ok=True)
    (variant/'lib/common/activation.hpp').write_text('''#pragma once
#include "type.hpp"
inline fp16 fp16_sigmoid(fp16 x) {
    fp16 v=fp16(fp16(x*fp16(0.25))+fp16(0.5));
    return v<fp16(0)?fp16(0):v>fp16(1)?fp16(1):v;
}
inline fp16 fp16_tanh(fp16 x) {
    return x<fp16(-1)?fp16(-1):x>fp16(1)?fp16(1):x;
}
''')
    manifest={'reference':'Unchanged egru/sim parser and EGRU source; reset at trial offsets.',
              'head':'FP16 bias followed by ascending-index rounded product/add; zero y skipped.',
              'hard_variant':'Only sigmoid/tanh replaced by chip formulas; not equivalent to true activations.',
              'source_sha256':{}}
    for name in ['lib/model/egru.cpp','lib/model/egru.hpp','lib/common/activation.hpp','python/parser.py']:
        manifest['source_sha256'][str(SIM/name)]=hashlib.sha256((SIM/name).read_bytes()).hexdigest()
    for name,source in [('reference',SIM),('hard',variant)]:
        subprocess.run(['g++','-std=c++17','-O3','-march=native','-I'+str(EIGEN),'-I'+str(source),
                        str(ROOT/'scripts/full_egru_reference.cpp'),str(source/'lib/model/egru.cpp'),
                        '-o',str(out/name)],check=True)
    for ds in range(4):
        directory=SIM/f'data/sdc_raw/bishop_{ds}/fp16'; target=out/f'bishop_{ds}'
        parser.export_from_npz(str(directory/'weights.npz'),str(directory/'test.npz'),str(target))
        with np.load(directory/'weights.npz') as w:
            for name in ['head_weight','head_bias']:w[name].astype('<f2').tofile(target/f'{name}.bin')
        with np.load(directory/'test.npz') as x:
            x['trial_offsets'].astype('<u8').tofile(target/'offsets.bin')
        for mode in ('reference','hard'):
            subprocess.run([str(out/mode),str(target),str(target/mode)],check=True)
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')


if __name__=='__main__':main()
