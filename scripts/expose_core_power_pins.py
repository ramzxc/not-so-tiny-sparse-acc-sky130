#!/usr/bin/env python3
"""Expose existing continuous GDS M4 supply stripes as LEF power pins."""
import hashlib
import json
from pathlib import Path
import re
import gdstk

root = Path(__file__).resolve().parents[1]
macro = root / 'macro/acc_hard_macro'
p = macro / 'acc_hard_macro.lef'
s = p.read_text()
lib = gdstk.read_gds(macro / 'acc_hard_macro.gds')
core = next(c for c in lib.cells if c.name == 'acc_hard_macro')
metal = core.get_polygons(layer=71, datatype=20)
height = float(re.search(r'SIZE\s+[\d.]+\s+BY\s+([\d.]+)', s)[1])
stripes = []
counts = {}
for name in ('VPWR', 'VGND'):
    match = re.search(r'  PIN ' + name + r'\n.*?  END ' + name, s, re.S)
    assert match
    pin = match[0]
    assert re.findall(r'LAYER\s+(\w+)\s*;', pin) == ['met4']
    rects = [list(map(float,v.split())) for v in re.findall(r'RECT\s+([^;]+);', pin)]
    columns = sorted({(v[0],v[2]) for v in rects})
    assert len(columns) == {'VPWR':22,'VGND':21}[name]
    rows = []
    for x1,x2 in columns:
        stripe = gdstk.rectangle((x1,0),(x2,height))
        assert not gdstk.boolean([stripe],metal,'not',precision=0.001), f'GDS metal gap: {name} {x1}'
        stripes.append(stripe)
        rows.append(f'        RECT {x1:g} 0 {x2:g} {height:g} ;')
    pin = re.sub(r'        RECT[^;]+;\n', '', pin)
    pin = pin.replace('      LAYER met4 ;','      LAYER met4 ;\n'+'\n'.join(rows))
    s = s[:match.start()] + pin + s[match.end():]
    counts[name] = len(columns)

def subtract(match):
    header,body=match.groups()
    shapes=[]
    for kind,raw in re.findall(r'(RECT|POLYGON)\s+([^;]+);',body):
        v=list(map(float,raw.split()))
        shapes.append(gdstk.rectangle(v[:2],v[2:]) if kind=='RECT' else gdstk.Polygon(list(zip(v[::2],v[1::2]))))
    result=gdstk.boolean(shapes,stripes,'not',precision=0.001)
    lines=[]
    for poly in result:
        tokens=[f'{v:g}' for xy in poly.points for v in xy]
        lines.append('      POLYGON')
        lines.extend('        '+' '.join(tokens[i:i+8]) for i in range(0,len(tokens),8))
        lines[-1]+=' ;'
    return header+'\n'+'\n'.join(lines)+'\n'
start=s.index('  OBS\n')
s=s[:start]+re.sub(r'^(    LAYER met4(?: SPACING 0)? ;)(.*?)(?=^    LAYER|^  END)',subtract,s[start:],flags=re.M|re.S)
p.write_text(s)
mp=macro/'manifest.json';m=json.loads(mp.read_text())
m['sha256']['acc_hard_macro.lef']=hashlib.sha256(p.read_bytes()).hexdigest()
m['lef_power_pins']='43 continuous M4 supply columns verified against actual GDS; full-height pins and matching M4 OBS subtraction. Reproduce with scripts/expose_core_power_pins.py.'
mp.write_text(json.dumps(m,indent=2)+'\n')
print('Verified existing GDS coverage and exposed supply columns:',counts)
