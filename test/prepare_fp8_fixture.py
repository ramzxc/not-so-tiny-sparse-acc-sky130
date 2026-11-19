"""External Flash stimulus for the FP8/1 KiB RTL integration tests."""
import json
from pathlib import Path
import sys
from fp8_reference import encode8, F

image = {}
def values(address, data):
    image.update((address+i, encode8(F(v))) for i,v in enumerate(data))

values(0, [1,2]); values(4,[3,4]); values(8,[0,0]); values(12,[1,1])
image[9]=0x80
values(0x200,[1,2,0,3,0,0]); image[0x204]=0x80
values(0x300,range(1,21))
for i in range(4):image[0x308+i]=0x7f
values(0x500,range(1,13))
for address, samples in [(0x400,[[1,0,3],[2,4,0],[0,-2,1]]),
                         (0x600,[[0,1,0],[0,0,2],[0,-2,0],[0,0,3]])]:
    packed=[]
    for c in (0,2):
        for sample in samples:packed.extend([sample[c],sample[c+1] if c+1<3 else 0])
    values(address,packed)
for i in range(1024):image[0x800+i]=((i*37+11)^(i>>1))&255
for i in range(1024):image[0x1000+i]=0
path=Path(sys.argv[1]);path.parent.mkdir(parents=True,exist_ok=True)
path.write_text(''.join(f'@{a:04x} {v:02x}\n' for a,v in sorted(image.items())))
