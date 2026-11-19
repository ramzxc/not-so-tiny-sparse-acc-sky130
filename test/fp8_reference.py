"""Independent exact-rational E4M3FN oracle (RNE, finite saturation)."""
from fractions import Fraction as F
from bisect import bisect_left
from pathlib import Path
import json

def decode8(x):
    s,e,m=x>>7,(x>>3)&15,x&7
    if e==15 and m==7: return None
    return (-1 if s else 1)*F(m if e==0 else 8+m)*F(2)**(-9 if e==0 else e-10)
VALUES=[decode8(x) for x in range(127)]
def encode8(x, negative_zero=False):
    if x is None: return 127
    sign=128 if x<0 or (x==0 and negative_zero) else 0
    x=abs(x)
    if x>=448: return sign|126
    i=bisect_left(VALUES,x)
    if i==0: return sign
    lo,hi=i-1,i
    dl,dh=x-VALUES[lo],VALUES[hi]-x
    code=lo if dl<dh or (dl==dh and lo%2==0) else hi
    return sign|code

def add8(a,b):
    x,y=decode8(a),decode8(b)
    return encode8(None if x is None or y is None else x+y, bool(a&b&128))
def mul8(a,b):
    x,y=decode8(a),decode8(b)
    return encode8(None if x is None or y is None else x*y,bool((a^b)&128))
def shift8(a,k):
    x=decode8(a)
    return encode8(None if x is None else x*F(2)**(-k),bool(a&128))
def from16(x):
    s,e,m=x>>15,(x>>10)&31,x&1023
    if e==31: return 127 if m else (s<<7)|126
    v=(-1 if s else 1)*F(m if e==0 else 1024+m)*F(2)**(-24 if e==0 else e-25)
    return encode8(v,bool(s))
def to16(x):
    import struct
    v=decode8(x)
    if v is None: return 0x7e00
    return int.from_bytes(struct.pack('>e',-0.0 if v==0 and x&128 else float(v)),'big')
def sigmoid(x):
    v=decode8(x)
    if v is None:return 127
    if v<=-2:return 0
    if v>=2:return 0x38
    return add8(shift8(x,2),0x30)
def tanh(x):
    v=decode8(x)
    if v is None:return 127
    if v<=-1:return 0xb8
    if v>=1:return 0x38
    return x



def sub8(a, b):
    return add8(a, b ^ 128)

def mac8(a, b, old=0, accumulate=False):
    return add8(mul8(a, b), old if accumulate else 0)

def activate(x, op):
    v = decode8(x)
    if v is None: return 127
    if op == 0: return x
    if op == 1: return 0 if x & 128 else x
    if op == 2: return sigmoid(x)
    if op == 3: return tanh(x)
    return 0x38 if v > 0 else 0
