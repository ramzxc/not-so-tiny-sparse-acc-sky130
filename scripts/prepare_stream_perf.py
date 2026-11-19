#!/usr/bin/env python3
"""Finite, exactly summable external Flash fixtures for stream equivalence."""
import json
from pathlib import Path
import numpy as np


def main():
    out = Path('/tmp/acc-stream-eval')
    out.mkdir(parents=True, exist_ok=True)
    image = ['@1000\n' + '00 38 00 b4\n' * 4096,
             '@7000\n' + '00 ' * 512 + '\n']
    cases = []
    address = 0x8000
    rng = np.random.default_rng(1081)

    def add(name, mask, g, repeats=4, sparse=True):
        nonlocal address
        b, c = mask.shape
        size = 4*((c+1)//2)*b
        acc = size+4*g
        assert acc+4*g*b <= 512
        packed = np.pad(mask, ((0,0),(0,c%2))).reshape(b,-1,2).transpose(1,0,2).astype('<f2').tobytes()
        image.append(f'@{address:04x}\n' + ' '.join(f'{v:02x}' for v in packed) + '\n')
        cases.append(dict(name=name, batch=b, columns=c, groups=g, repeats=repeats,
                          sparse=sparse, source=address, input_bytes=size, buffer=size,
                          acc=acc, union_columns=int(mask.any(axis=0).sum()),
                          sample_active=mask.sum(axis=1).tolist()))
        address += size

    for b in (1,2,4):
        for kind in ('zero','full','random','dense'):
            m = rng.random((b,19)) < .3
            if kind == 'zero': m[:] = False
            if kind == 'full': m[:] = True
            add(f'b{b}_{kind}', m, 9, sparse=kind != 'dense')
        c,g = {1:(100,39), 2:(62,22), 4:(24,16)}[b]
        x = np.load('/docker/projects/egru/sim/data/sdc_raw/bishop_0/fp16/test.npz')['inputs']
        add(f'b{b}_bishop', x[100:100+b,:c] != 0, g)
    # Two repeat counts determine startup/drain costs without assuming amortization.
    for n in (1,2):
        add(f'b1_small_n{n}', np.zeros((1,19),dtype=bool), 9, n)
        add(f'b1_large_n{n}', np.ones((1,19),dtype=bool), 9, n)
    mixed = []
    for b in (1,2,4):
        add(f'b{b}_mixed', np.ones((b,19),dtype=bool), 9)
        case = cases.pop()
        case.update(run_columns=[19,1,7,2], total_bursts=29, total_active=[29]*b)
        mixed.append(case)
    assert address < 0x10000
    (out/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')
    (out/'mixed.json').write_text(json.dumps(mixed,indent=2)+'\n')
    (out/'inputs.hex').write_text(''.join(image))
    print(len(cases), 'cases', out)


if __name__ == '__main__':
    main()
