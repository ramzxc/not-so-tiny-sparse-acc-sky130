#!/usr/bin/env python3
"""Build complete batch-1 EGRU+FC UART workloads, without changing RTL."""
import argparse,json
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/fp8_full'
# Eight-byte-aligned DMA scratch; temporary vectors are live only within one
# two-neuron state update, so the next pair can reuse the same four bytes.
WEIGHT_BASE=960
U_BASE=984
R_BASE=992
Z_BASE=1000
TEMP_A=1008
TEMP_B=1010
PHASES=['initialization','input_and_bias','input_ur','recurrent','gates','input_z','state','head','fence']
class Program:
    def __init__(self): self.words=[];self.phase=0;self.addr=None;self.cfg={}
    def emit(self,*words): self.words.extend((self.phase<<16)|w for w in words)
    def address(self,a):
        if self.addr is None or (self.addr&4095)!=(a&4095):self.emit(0x2000|(a&4095))
        if self.addr is None or self.addr>>12!=a>>12:self.emit(0x3000|(a>>12))
        self.addr=a
    def dma(self,src,dst,count):
        self.address(src);self.emit(0xc000);self.address(dst);self.emit(0xc400,0xc800|count)
    def config(self,key,value,opcode,address=False):
        if self.cfg.get(key)!=value:
            if address:self.address(value);self.emit(opcode)
            else:self.emit(opcode|value)
            self.cfg[key]=value
    def micro(self,inp,w,acc,groups,cols,stride):
        self.config('acc',acc,0xa800,True);self.config('groups',groups,0xac00)
        self.config('buffer',WEIGHT_BASE,0xbc00,True);self.config('stride',stride,0xbc01,True)
        self.address(inp);self.emit(0xa001);self.address(w);self.emit(0xa400,0xb000|cols,0xb403)
        self.addr=None
    def op(self,a,b,dst,op=2,act=0):
        self.emit(0x8000);self.address(a);self.emit(0x4400)
        self.emit(0x8400);self.address(b);self.emit(0x4400)
        self.emit(0xffff,0x6000|(op<<10)|(act<<7),0xffff,0x9000)
        self.address(dst);self.emit(0x5400)
    def fence(self):self.emit(0xffff,0)

def build(ds,t,consumer=False,stream=False):
    data=ROOT/f'reports/fp8_1k/data/bishop_{ds}';trace=OUT/f'bishop_{ds}'
    raw=lambda n:np.fromfile(data/f'{n}.bin',dtype=np.uint8)
    w=raw('kernel').reshape(-1,768);r=raw('recurrent_kernel').reshape(256,768);d=len(w)
    assert d <= 188, "Input exceeds the reserved SRAM input span"
    add=np.fromfile(OUT/'tables/add.bin',dtype=np.uint8).reshape(256,256)
    bias=add[raw('bias'),raw('recurrent_bias')]
    flash=bytearray(1048576)
    def put(a,v):v=bytes(v);flash[a:a+len(v)]=v
    put(0x100,[0x38,0x38]);put(0x102,[0,0]);put(0x104,raw('head_bias'))
    put(0x1000,raw('inputs').reshape(-1,d)[t]);put(0x2200,raw('threshold'));put(0x3000,raw('head_weight'))
    offsets=np.fromfile(trace/'offsets.bin',dtype='<u8')
    for name,addr in [('y',0x2000),('c',0x2100)]:
        values=np.fromfile(trace/f'{name}.bin',dtype=np.uint8).reshape(-1,256)
        put(addr,values[t-1] if t and t not in offsets else bytes(256))
    blocks=[];ptr=0x10000
    for s in range(0,256,8):
        ix=np.r_[s:s+8,256+s:264+s,512+s:520+s]
        put(0x4000+s*3,bias[ix]);wx=ptr;put(ptr,w[:,ix].tobytes());ptr+=d*24
        ur=ptr;put(ptr,r[:,ix].tobytes());ptr+=256*24;blocks.append((s,wx,ur))
    p=Program();p.dma(0x2000,256,128);p.dma(0x2100,0,128);p.dma(0x100,1022,1);p.fence();p.words.append(0xffff0001)
    p.phase=1
    if not stream:p.dma(0x1000,768,(d+1)//2)
    p.dma(0x104,1020,1)
    for s,wx,ur in blocks:
        p.phase=1;p.dma(0x4000+s*3,U_BASE,12)
        p.phase=2;p.micro(768,wx,U_BASE,8,d,24)
        p.phase=3
        for j in (0,128):p.micro(256+j,ur+j*24,U_BASE,12,128,24)
        p.phase=4
        for i in range(0,16,2):p.op(U_BASE+i,1022,U_BASE+i,act=3)
        for i in range(0,8,2):p.op(Z_BASE+i,R_BASE+i,Z_BASE+i)
        p.phase=5;p.micro(768,wx+16,Z_BASE,4,d,24)
        p.phase=6
        for i in range(0,8,2):p.op(Z_BASE+i,1022,Z_BASE+i,act=2)
        p.dma(0x2200+s,WEIGHT_BASE,4)
        for i in range(0,8,2):
            a,b=TEMP_A,TEMP_B;u,z=U_BASE+i,Z_BASE+i;c,y=s+i,512+s+i;th=WEIGHT_BASE+i
            p.op(1022,u,a,1);p.op(a,z,a);p.op(u,c,b);p.op(a,b,b,0)
            p.op(b,th,y,1,4);p.op(y,th,a);p.op(b,a,c,1);p.op(y,b,y)
            # Non-event output is positive zero, including a negative membrane.
            p.dma(0x102,a,1);p.op(y,a,y,0)
        p.phase=7;p.micro(512+s,0x3000+s*2,1020,1,8,2)
    p.phase=8;p.fence()
    if consumer:
        p.words.append(0xffff0003);p.phase=9
        p.emit(0x8000);p.address(1020);p.emit(0x4400)
        p.emit(0x8400);p.address(1022);p.emit(0x4400)
        p.emit(0xffff,0x6800,0xffff,0x9000);p.address(0xf0000);p.emit(0x5000);p.fence()
    p.words.append(0xffff0002)
    case=OUT/f'{"psram" if stream else "consumer" if consumer else "case"}_bishop_{ds}_step_{t}';case.mkdir(exist_ok=True)
    (case/'flash.hex').write_text(''.join(f'{v:02x}\n' for v in flash[:ptr]))
    (case/'commands.hex').write_text(''.join(f'{v:08x}\n' for v in p.words))
    expected=[]
    for name,addr,size in [('c',0,256),('y',512,256),('head',1020,2)]:
        v=np.fromfile(trace/f'{name}.bin',dtype=np.uint8).reshape(-1,size)[t]
        expected.extend(((addr+i)<<32)|int(v[i])|(int(v[i+1])<<8) for i in range(0,size,2))
    (case/'expected.hex').write_text(''.join(f'{v:016x}\n' for v in expected))
    meta=dict(dataset=ds,step=t,input_width=d,words=len(p.words),phases=PHASES+(['output_flash'] if consumer else []),flash_end=ptr,
              layout=dict(c=[0,255],y_old=[256,511],y_new=[512,767],input=[768,955],weights=[WEIGHT_BASE,WEIGHT_BASE+23],u=[U_BASE,U_BASE+7],r=[R_BASE,R_BASE+7],z=[Z_BASE,Z_BASE+7],temp_a=[TEMP_A,TEMP_A+1],temp_b=[TEMP_B,TEMP_B+1],fc=[1020,1021],ones=[1022,1023]))
    (case/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n');return str(case)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--consumer',action='store_true');parser.add_argument('--holdouts',action='store_true');args=parser.parse_args()
    if args.holdouts and not args.consumer:parser.error('--holdouts requires --consumer')
    rng=np.random.default_rng(20261119)
    cases=[]
    for ds in range(4):
        stats=np.genfromtxt(OUT/f'bishop_{ds}/activity.csv',delimiter=',',names=True,dtype=int)
        selected={int(np.argsort(stats['input']+stats['previous'])[len(stats)//2]),int(rng.integers(101,len(stats)))} if args.holdouts else {0,100,int(np.argmax(stats['input']+stats['previous']))}
        for t in sorted(selected):cases.append(build(ds,t,args.consumer))
    (OUT/('consumer_holdout_cases.json' if args.holdouts else 'consumer_cases.json' if args.consumer else 'cases.json')).write_text(json.dumps(cases,indent=2)+'\n')
