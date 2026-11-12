#!/usr/bin/env python3
"""Exactly rescale ICC2 0.1nm DBU to Magic-compatible 1nm DBU; no rounding."""
import hashlib,json,struct
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];p=ROOT/'macro/acc_hard_macro';f=p/'acc_hard_macro.gds'
old=f.read_bytes();new=bytearray(old)
def real8(raw):
 return (-1 if raw[0]&128 else 1)*16.0**((raw[0]&127)-64)*int.from_bytes(raw[1:],'big')/2**56 if any(raw) else 0.0
def encode(v):
 exponent=64
 while v>=1: v/=16;exponent+=1
 while v<1/16:v*=16;exponent-=1
 return bytes([exponent])+round(v*2**56).to_bytes(7,'big')
offset=0;values=0;changed=0
while offset<len(old):
 n,k=struct.unpack_from('>HH',old,offset);assert n>=4
 if k==0x0305:
  u,dbu=real8(old[offset+4:offset+12]),real8(old[offset+12:offset+20])
  assert abs(dbu-1e-10)<1e-22, 'Expected unnormalized ICC2 0.1nm DBU'
  new[offset+4:offset+20]=encode(u*10)+encode(1e-9)
 elif k in (0x1003,0x0f03,0x3003,0x3103): # XY, WIDTH, BGNEXTN, ENDEXTN
  nums=struct.unpack('>'+str((n-4)//4)+'i',old[offset+4:offset+n])
  assert all(x%10==0 for x in nums), 'Non-integral conversion; refuse geometry rounding'
  new[offset+4:offset+n]=struct.pack('>'+str(len(nums))+'i',*(x//10 for x in nums))
  values+=len(nums);changed+=1
 offset+=n
 if k==0x0400:break
sha=lambda b:hashlib.sha256(b).hexdigest()
f.write_bytes(new)
report={'source_sha256':sha(old),'output_sha256':sha(new),'source_dbu_m':1e-10,'output_dbu_m':1e-9,'length_values_rescaled_exactly':values,'length_records':changed,'rounding':False,'geometry_and_transforms_preserved':True,'other_records_preserved':True}
(p/'units_validation.json').write_text(json.dumps(report,indent=2)+'\n')
m=json.loads((p/'manifest.json').read_text());m['sha256'][f.name]=sha(new);m['gds_units']='units_validation.json: exact 0.1nm to 1nm DBU conversion without rounding'
(p/'manifest.json').write_text(json.dumps(m,indent=2)+'\n');print(json.dumps(report,indent=2))
