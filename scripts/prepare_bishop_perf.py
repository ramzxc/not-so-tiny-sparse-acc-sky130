#!/usr/bin/env python3
"""Prepare external Flash input patterns and manifests for RTL timing calibration."""
import argparse
import json
from pathlib import Path
import numpy as np

def features(mask,g):
    b,c=mask.shape;p=(c+1)//2;u=int(mask.any(axis=0).sum());a=int(mask.sum())
    scan=sum(int(np.flatnonzero(mask[:,j])[0])+1 if mask[:,j].any() else b for j in range(c))
    if b==1:return [1,g,p,c,u,u*g]
    return [1,g,p,c,scan,u,u*g,u*g*b,a*g]

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,default=Path('/tmp/acc-bishop-eval'))
    args=ap.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    rng=np.random.default_rng(704);cases=[];image=[];address=0x4000
    def add(name,mask,g,validation=False):
        nonlocal address
        b,c=mask.shape;n=4*((c+1)//2)*b;acc=n+4*g
        assert acc+4*g*b<=512
        padded=np.pad(mask,((0,0),(0,c%2)))
        packed=padded.reshape(b,-1,2).transpose(1,0,2).astype('<f2').tobytes()
        image.append(f'@{address:04x}\n'+' '.join(f'{x:02x}' for x in packed)+'\n')
        cases.append({'name':name,'batch':b,'columns':c,'groups':g,'source':address,
                      'input_bytes':n,'buffer':n,'acc':acc,'features':features(mask,g),
                      'union_columns':int(mask.any(axis=0).sum()),'validation':validation})
        address+=n
    for b in (1,2,4):
        for c,g in [(5,1),(8,3),(9,7)]:
            for kind in ('zero','full','first','last'):
                mask=np.zeros((b,c),dtype=bool)
                if kind=='full':mask[:]=True
                elif kind=='first':mask[0,::2]=True
                elif kind=='last':mask[-1,1::2]=True
                add(f'cal_b{b}_c{c}_g{g}_{kind}',mask,g)
        # C16 completes calibration geometry; C19 is held out from the fit.
        for c,g in [(16,7),(19,9)]:
            add(f'random_b{b}_c{c}',rng.random((b,c))<0.3,g,True)
        # Actual nonzero masks, selected away from trial starts, also withheld.
        for ds in (0,1):
            x=np.load(f'/docker/projects/egru/sim/data/sdc_raw/bishop_{ds}/fp16/test.npz')['inputs']
            add(f'bishop_{ds}_b{b}',x[100:100+b,:32]!=0,3,True)
    assert address<=65536
    (args.output/'inputs.hex').write_text(''.join(image))
    (args.output/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')
    print(len(cases),'cases',args.output)
if __name__=='__main__':main()
