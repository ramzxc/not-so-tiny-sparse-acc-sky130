#!/usr/bin/env python3
"""Generate full FP8 EGRU+FC traces from the converted Bishop test datasets."""
import json
from pathlib import Path
import subprocess
import sys
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'test'))
from fp8_reference import add8,mul8,sigmoid,tanh,decode8

def main():
    out=ROOT/'reports/fp8_full';out.mkdir(parents=True,exist_ok=True)
    tables=out/'tables';tables.mkdir(exist_ok=True)
    for name,fn in [('add',add8),('mul',mul8)]:
        (tables/f'{name}.bin').write_bytes(bytes(fn(a,b) for a in range(256) for b in range(256)))
    for name,fn in [('sigmoid',sigmoid),('tanh',tanh)]:
        (tables/f'{name}.bin').write_bytes(bytes(fn(a) for a in range(256)))
    np.array([float(decode8(a)) if decode8(a) is not None else np.nan for a in range(256)],dtype='<f4').tofile(tables/'values.bin')
    subprocess.run(['g++','-std=c++17','-O3',str(ROOT/'scripts/fp8_egru_trace.cpp'),'-o',str(out/'reference')],check=True)
    for ds in range(4):
        data=ROOT/f'reports/fp8_1k/data/bishop_{ds}';trace=out/f'bishop_{ds}';trace.mkdir(exist_ok=True)
        with np.load(data/'test.npz') as z:z['trial_offsets'].astype('<u8').tofile(trace/'offsets.bin')
        subprocess.run([str(out/'reference'),str(data),str(tables),str(trace)],check=True)
    (out/'reference_contract.json').write_text(json.dumps(dict(
        topology='egru/sim: input U/R, recurrent U/R/Z, sigmoid U/R, reset recurrent Z, input Z, tanh Z, cell/event/reset, FC',
        arithmetic='E4M3FN rounded product then rounded addition; chip hard sigmoid/tanh',
        bias='FP8 add of the separately converted bias and recurrent_bias arrays',
        head='FP8 bias, then ascending-hidden-index rounded multiply/add of emitted y',
        reset='at every trial offset',
        accuracy='Not bit-equivalent to original FP16/true-sigmoid model; no task-accuracy claim'),indent=2)+'\n')

if __name__=='__main__':main()
