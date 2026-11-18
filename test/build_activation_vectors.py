"""Independent binary16 oracle for tiny's hard activation formulas."""
import math
import struct
import sys

def half(x):
    try:return int.from_bytes(struct.pack('<e',x),'little')
    except OverflowError:return 0xfc00 if x<0 else 0x7c00

def val(x):return struct.unpack('<e',x.to_bytes(2,'little'))[0]

def expected(bits,operation):
    x=val(bits)
    if math.isnan(x):return 0x7e00
    if operation==0:return bits
    if operation==1:return 0 if bits&0x8000 else bits
    if operation==2:
        y=val(half(val(half(x/4))+0.5))
        return half(min(1.0,max(0.0,y)))
    if operation==3:return half(min(1.0,max(-1.0,x)))
    return 0x3c00 if x>0 else 0

with open(sys.argv[1],'w') as f:
    for op in range(5):
        for bits in range(65536):f.write(f'{expected(bits,op):04x}\n')
