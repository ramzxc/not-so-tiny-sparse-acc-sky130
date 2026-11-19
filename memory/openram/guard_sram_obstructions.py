"""Add conservative routing clearance to a GDS-derived SRAM LEF.

All ports stay byte-identical. LI1/M1/M2 are reserved for SRAM internals;
upper metal and cut obstructions are enlarged by the SKY130 minimum spacing.
No GDS geometry is changed and no original obstruction is removed.
"""
import argparse
from pathlib import Path
import re
import gdstk
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('input',type=Path);p.add_argument('output',type=Path)
a=p.parse_args();text=a.input.read_text();head=text.split('   OBS')[0]
w,h=map(float,re.search(r'SIZE\s+(\S+)\s+BY\s+(\S+)',head).groups())
def layers(text):
    result={};layer=None
    for m in re.finditer(r'LAYER\s+(\w+)[^;]*;|(RECT|POLYGON)\s+([^;]+);',text):
        if m[1]:layer=m[1];result.setdefault(layer,[]);continue
        v=list(map(float,m[3].split()))
        result[layer].append(gdstk.rectangle(v[:2],v[2:]) if m[2]=='RECT' else gdstk.Polygon(list(zip(v[::2],v[1::2]))))
    return result
pins=layers(head);old=layers(text.split('   OBS',1)[1]);out=[head,'   OBS\n']
for layer,spacing in {'li1':.17,'met1':.14,'met2':.14,'met3':.30,'met4':.30,'via':.17,'via2':.20,'via3':.20}.items():
    original=old.get(layer,[])
    if layer in ('li1','met1','met2'):
        assert not pins.get(layer),f'Cannot block SRAM pin layer {layer}'
        inset=0 if layer=="li1" else .30
        new=[gdstk.rectangle((inset,inset),(w-inset,h-inset))]
    else:
        grown=gdstk.offset(original,spacing,join='miter',precision=.001,use_union=True)
        new=gdstk.boolean(grown,pins.get(layer,[]),'not',precision=.001)
    assert not gdstk.boolean(original,new,'not',precision=.001),f'Lost obstruction on {layer}'
    assert not gdstk.boolean(new,pins.get(layer,[]),'and',precision=.001),f'Blocked pin on {layer}'
    out.append(f'      LAYER {layer} ;\n')
    for poly in new:
        out.append('         POLYGON\n')
        out.extend(f'            {x:.3f} {y:.3f}\n' for x,y in poly.points)
        out.append('         ;\n')
    print(layer,len(original),len(new),flush=True)
name=re.search(r'^MACRO\s+(\S+)',head,re.M)[1]
out.append(f'   END\nEND {name}\nEND LIBRARY\n')
a.output.write_text(''.join(out))
