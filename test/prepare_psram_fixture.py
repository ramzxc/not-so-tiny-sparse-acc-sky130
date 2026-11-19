"""Board-preloaded PSRAM images for UART input / autonomous program tests."""
import json,sys
from pathlib import Path
from fp8_reference import add8,mul8

def address(a):return [0x2000|(a&4095),0x3000|(a>>12)]
def load(a,weight=False,sram=False):return [0x8400 if weight else 0x8000]+address(a)+[0x4400 if sram else 0x4000]
def store(a,sram=False):return [0xffff,0x9000]+address(a)+[0x5400 if sram else 0x5000]
def dma(src,dst,n):return address(src)+[0xc000]+address(dst)+[0xc400,0xc800|n]
def main(path):
    image={};cases=[]
    def put(a,b):image.update({a+i:int(v) for i,v in enumerate(b)})
    def program(a,w):put(a,b''.join(int(v).to_bytes(2,'little') for v in w));return len(w)
    put(0x2000,[0x38,0x38]);put(0x2010,[0x40,0x44]);put(0x2200,bytes(64))
    w=[0,0,0]+load(768,sram=True)+[0]+load(0x2010,True)+[0xffff,0x6800]+store(0x3000)+[0xffff]
    cases.append(dict(name='multiply',base=0x10000,words=program(0x10000,w),payload=[0x38,0x40],expected=[0x40,0x4c]))
    weights=[0x38,0x40,0x30,0xb8,0x40,0x38,0xb0,0x30,0x38,0x30,0x40,0x38]
    put(0x2100,weights)
    for batch in (1,3,4):
        payload=[];x=[]
        for b in range(batch):x.append([0x38 if b%2==0 else 0,0x40,0 if b%2==0 else 0x38])
        for pair in range(2):
            for b in range(batch):payload.extend([x[b][2*pair],x[b][2*pair+1] if pair==0 else 0])
        expected=[]
        for group in range(2):
            for b in range(batch):
                for lane in range(2):
                    s=0
                    for c in range(3):
                        if x[b][c]&127:s=add8(s,mul8(x[b][c],weights[c*4+group*2+lane]))
                    expected.append(s)
        w=dma(0x2200,0,2*batch)+address(768)+[0xa001]+address(0x2100)+[0xa400]+address(0)+[0xa800,0xac02,0xb003,0xb800|batch]+address(64)+[0xbc00]+address(4)+[0xbc01]
        while len(w)%4!=3:w.append(0)
        w.append(0xb403)
        for i in range(0,4*batch,2):w+=load(i,sram=True)+load(0x2000,True)+[0xffff,0x6800]+store(0x3000+i)
        w+=[0xffff];base=0x11000+batch*0x1000
        cases.append(dict(name=f'micro_batch_{batch}',base=base,words=program(base,w),payload=payload,expected=expected))
    # Compact scalar modes preserve dense NaNs and sparse +/-zero behavior.
    put(0x2500,[0x7f,0x38])
    for kind in range(2,10):
        for zeros in (False,True):
            payload=[0,0x80] if zeros else [0x38,0x40]
            scalar=payload[kind&1];sparse=kind in (4,5,8,9)
            expected=[0,0] if sparse and scalar&127==0 else [mul8(scalar,w) for w in (0x7f,0x38)]
            w=dma(0x2500,64,1)
            if kind<6:w += [0xe200|(64//2),0xffff,0xe000|(kind<<9)|(768//2)]
            else:w += [0xe000|(768//2),0xffff,0xe000|(kind<<9)|(64//2)]
            w += [0xffff,0x6800,0xffff,0xf400|(128//2),0xffff]
            w += load(128,sram=True)+load(0x2000,True)+[0xffff,0x6800]+store(0x3000)+[0xffff]
            base=0x20000+len(cases)*0x1000
            cases.append(dict(name=f'compact_{kind}_zeros{int(zeros)}',base=base,
                              words=program(base,w),payload=payload,expected=expected))
    put(0x2600,bytes(i&255 for i in range(512)));put(0x2800,bytes([0xa5])*1024)
    for dst,count in [(0,255),(2,255),(4,127),(6,31)]:
        w=dma(0x2800,0,255)+dma(0x29fe,510,255)+dma(0x2bfc,1020,2)+dma(0x2601,dst,count)+[0xffff]
        snapshot=[0xa5]*1024;snapshot[dst:dst+2*count]=[(i+1)&255 for i in range(2*count)]
        base=0x20000+len(cases)*0x1000
        cases.append(dict(name=f'row_dma_{dst}_{count}',base=base,words=program(base,w),payload=[],expected=[],sram_expected=snapshot))
    # Final legal vector and odd external vector crossing a 64-bit boundary.
    put(0x7ffffc,[0x38,0x40]);put(0x2407,[0x40,0x44])
    for name,src in [('edge_data',0x7ffffc),('unaligned',0x2407)]:
        w=load(src)+load(0x2000,True)+[0xffff,0x6800]+store(0x3000)+[0xffff];base=0x18000+len(cases)*0x100
        cases.append(dict(name=name,base=base,words=program(base,w),payload=[],expected=[image[src],image[src+1]]))
    w=[0,0,0]+load(0x2407)+[0]+load(0x2000,True)+[0xffff,0x6800]+store(0x3000)+[0xffff]
    cases.append(dict(name='data_priority_hazard',base=0x1b000,words=program(0x1b000,w),payload=[],expected=[0x40,0x44]))
    program(0x7ffffe,[0]);program(0x19000,dma(0x7ffffe,0,2)+[0xffff])
    w=load(0x7fffff)+[0xffff];program(0x19100,w)
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w') as f:
        last=-2
        for a in sorted(image):
            if a!=last+1:f.write(f'@{a:x}\n')
            f.write(f'{image[a]:02x}\n');last=a
    p.with_suffix('.json').write_text(json.dumps(cases,indent=2)+'\n')
if __name__=='__main__':main(sys.argv[1])
