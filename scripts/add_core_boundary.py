#!/usr/bin/env python3
"""Add only the SKY130 PR boundary to the ICC2 core GDS; preserve every other byte."""
import hashlib,json,re,struct
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=ROOT/'macro/acc_hard_macro'
f=p/'acc_hard_macro.gds'; original=f.read_bytes()
name='acc_hard_macro'
size=tuple(map(float,re.search(r'SIZE\s+([\d.]+)\s+BY\s+([\d.]+)',(p/'acc_hard_macro.lef').read_text()).groups()))
def real8(raw):
 if not any(raw):return 0.0
 return (-1 if raw[0]&128 else 1)*16.0**((raw[0]&127)-64)*int.from_bytes(raw[1:],'big')/2**56
def record(kind,payload=b''):
 return struct.pack('>HH',len(payload)+4,kind)+payload
cell=None;offset=0;target_end=None;precision=None;boundary_count=0;layer=None;dtype=None
while offset<len(original):
 length,kind=struct.unpack_from('>HH',original,offset);assert length>=4
 payload=original[offset+4:offset+length]
 if kind==0x0305:precision=real8(payload[8:16])
 elif kind==0x0606:cell=payload.rstrip(b'\0').decode()
 elif cell==name:
  if kind==0x0800:layer=dtype=None
  elif kind==0x0d02:layer=struct.unpack('>H',payload)[0]
  elif kind==0x0e02:dtype=struct.unpack('>H',payload)[0]
  elif kind==0x1100 and (layer,dtype)==(235,4):boundary_count+=1
  elif kind==0x0700:target_end=offset
 offset+=length
 if kind==0x0400:
  assert not any(original[offset:]), "Unexpected nonzero trailer"
  break
assert offset<=len(original) and target_end is not None and precision
if boundary_count:raise SystemExit('Core PR boundary already present; refusing to duplicate it')
coords=[round(x*1e-6/precision) for x in size]
x,y=coords
addition=(record(0x0800)+record(0x0d02,struct.pack('>H',235))+record(0x0e02,struct.pack('>H',4))+
 record(0x1003,struct.pack('>10i',0,0,x,0,x,y,0,y,0,0))+record(0x1100))
updated=original[:target_end]+addition+original[target_end:]
assert updated[:target_end]+updated[target_end+len(addition):]==original
f.write_bytes(updated)
sha=lambda s:hashlib.sha256(s).hexdigest()
report={'source_sha256':sha(original),'output_sha256':sha(updated),'cell':name,'layer':[235,4],'bbox_um':[0,0,*size],'added_bytes':len(addition),'all_other_bytes_unchanged':True}
(p/'boundary_validation.json').write_text(json.dumps(report,indent=2)+'\n')
m=json.loads((p/'manifest.json').read_text());m['sha256'][f.name]=sha(updated);m['pr_boundary']='boundary_validation.json: only added top-level SKY130 235/4 boundary; all other GDS records unchanged'
(p/'manifest.json').write_text(json.dumps(m,indent=2)+'\n')
print(json.dumps(report,indent=2))
