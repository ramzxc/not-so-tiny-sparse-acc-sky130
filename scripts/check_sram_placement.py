#!/usr/bin/env python3
"""Read actual macro geometry and check right-side placement/PG contracts.

Generates a geometry-only preview, not a routed layout or timing/DRC signoff.
"""
import json,re,hashlib,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/sram_right';OUT.mkdir(parents=True,exist_ok=True)
cfg=json.loads((ROOT/'src/config.json').read_text());name='tt_sram_1rw_64x128_buffered_sky130';macro=cfg['MACROS'][name]
leaf=ROOT/'memory/openram/generated'/name
lef=(leaf/f'{name}.lef').read_text();w,h=map(float,re.search(r'SIZE\s+([\d.]+)\s+BY\s+([\d.]+)',lef).groups())
x,y=macro['instances']['core.itf.memory.size_1k.macro']['location'];assert macro['instances']['core.itf.memory.size_1k.macro']['orientation']=='N'
die=(0,0,1378.16,225.76);core=(5.52,5.44,1372.64,220.32)
assert core[0]<=x and core[1]<=y and x+w<=core[2]+1e-8 and y+h<=core[3]
obs=cfg['PDN_OBSTRUCTIONS'][0];assert obs[0]=='met4' and obs[1]<=x-10+1e-8 and obs[2]<=0 and obs[3]>=x+w+10-1e-8 and obs[4]>=die[3]
# N orientation keeps control pins facing left, the open logic side.
controls={}
for pin in ['clk0','csb0','web0']:
 b=lef.split('PIN '+pin+'\n')[1].split('END '+pin)[0]
 rect=list(map(float,re.search(r'RECT\s+([\d.\s]+);',b)[1].split()));assert rect[2]<w/2;controls[pin]=rect
source=json.loads((leaf/'source_summary.json').read_text())
for ext,key in [('.gds','.gds'),('.lvs.sp','.lvs.sp')]:
 assert hashlib.sha256((leaf/f'{name}{ext}').read_bytes()).hexdigest()==source['physical']['checked_sha256'][key]
# Evaluate ICC2 coordinate definitions without calling ICC2 or modifying a block.
tcl='source pnr/core/setup.tcl\nputs "ORIGIN $::tt_core::sram_origin"\nputs "SIZE $::tt_core::sram_size"\nputs "VIA $::tt_core::sram_via_bbox"\nforeach item $::tt_core::power_stripes {puts "STRIPE $item"}\nforeach item $::tt_core::pg_side_leads {puts "LEAD $item"}\n'
r=subprocess.run(['tclsh'],input=tcl,text=True,cwd=ROOT,capture_output=True,check=True);assert not r.stderr,r.stderr
stripes=[];leads=[]
for line in r.stdout.splitlines():
 if line.startswith('ORIGIN '):assert all(abs(a-b)<1e-6 for a,b in zip(map(float,line.split()[1:]),(x-core[0],y-core[1])))
 if line.startswith('SIZE '):assert tuple(map(float,line.split()[1:]))==(w,h)
 if line.startswith(('STRIPE ','LEAD ')):
  kind,net,rect=re.match(r'(\w+) (\w+) \{(.*)\}',line).groups();box=list(map(float,rect.split()))
  assert 0<=box[0]<box[2]<=1367.12 and 0<=box[1]<box[3]<=214.88
  (stripes if kind=='STRIPE' else leads).append((net,box))
assert len(leads)==4 and {n for n,_ in leads}=={'VPWR','VGND'}
for net,b in stripes:assert b[2]<=x-core[0]-10+1e-6
# Each side lead enters the corresponding actual M3 ring from a same-net column.
for net,b in leads:
 assert any(n==net and q[0]==b[0] and q[1]<=b[1] and q[3]>=b[3] for n,q in stripes)
 pin='vccd1' if net=='VPWR' else 'vssd1';body=lef.split('PIN '+pin+'\n')[1].split('END '+pin)[0]
 rings=[]
 for layer,rect in re.findall(r'LAYER\s+(\w+)\s*;\s*RECT\s+([\d.\s]+);',body):
  q=list(map(float,rect.split()))
  if layer=='met3' and q[2]-q[0]>w/2:rings.append([q[0]+x-core[0],q[1]+y-core[1],q[2]+x-core[0],q[3]+y-core[1]])
 assert any(abs(q[1]-b[1])<1e-6 and abs(q[3]-b[3])<1e-6 and b[2]>q[0] for q in rings)
# Parse Tcl script completeness; integrated OpenDB execution is a separate check.
for file in ['src/tcl/pdn.tcl','pnr/core/apply_pg.tcl']:
 check=subprocess.run(['tclsh'],input=f'set f [open {file}];set s [read $f];close $f;puts [info complete $s]\n',text=True,cwd=ROOT,capture_output=True,check=True)
 assert check.stdout.strip()=='1'
report=dict(macro=name,size_um=[w,h],tile_origin_um=[x,y],core_origin_um=[x-core[0],y-core[1]],
 bbox_um=[x,y,x+w,y+h],left_logic_width_excluding_halo_um=x-10-core[0],
 core_vertical_clearances_um=[y-core[1],core[3]-y-h],power_stripes=len(stripes),side_leads=leads,
 checks='outline, core containment, keepout, left-facing control pins, source physical hashes, cross-flow coordinates, PG lead-to-ring/column geometry, Tcl completeness',
 not_checked='integrated placement, PDN connectivity/DRC, routed signal access, extracted timing; no synthesis or PnR executed')
(OUT/'placement.json').write_text(json.dumps(report,indent=2)+'\n')
svg=['<svg xmlns="http://www.w3.org/2000/svg" viewBox="-25 -70 1430 345">','<rect x="-25" y="-70" width="1430" height="345" fill="white"/>','<text x="0" y="-35" font-size="22" font-family="sans-serif">8 x 2 — buffered SRAM at right (geometry only)</text>',f'<rect width="1378.16" height="225.76" fill="#edf3f8" stroke="#20334d" stroke-width="2"/>',f'<rect x="5.52" y="5.44" width="1367.12" height="214.88" fill="none" stroke="#7790a0" stroke-dasharray="5 4"/>',f'<rect x="5.52" y="5.44" width="{x-10-core[0]}" height="214.88" fill="#cbe8d5"/>',f'<rect x="{x}" y="{225.76-y-h}" width="{w}" height="{h}" fill="#bfcee9" stroke="#254a88"/>','<text x="90" y="100" font-size="24" font-family="sans-serif">Logic region</text>',f'<text x="{x+180}" y="100" font-size="24" font-family="sans-serif">1 KiB SRAM — 842.335 x 214.355 um</text>',f'<text x="{x+190}" y="135" font-size="18" font-family="sans-serif">N orientation; control pins on left</text>']
for net,b in leads:
 svg.append(f'<rect x="{b[0]+core[0]}" y="{225.76-b[3]-core[1]}" width="{b[2]-b[0]}" height="{b[3]-b[1]}" fill="'+('#d7473f' if net=='VPWR' else '#303a44')+'"/>')
svg+=['<text x="0" y="255" font-size="16" font-family="sans-serif">10 um horizontal keepout. No routed placement, connectivity or DRC claim.</text>','</svg>']
(OUT/'floorplan.svg').write_text('\n'.join(svg));print(json.dumps(report,indent=2))
