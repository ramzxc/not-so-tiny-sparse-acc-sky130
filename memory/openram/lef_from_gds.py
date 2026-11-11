"""Build routing OBS from final GDS, preserving and checking public LEF pins."""
import argparse
import gdstk,re,json
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument("gds",type=Path);p.add_argument("pin_lef",type=Path);p.add_argument("output",type=Path)
a=p.parse_args();dst=a.output.parent;dst.mkdir(parents=True,exist_ok=True);name=a.gds.stem
lef=a.pin_lef.read_text();head=lef.split('   OBS')[0];top=gdstk.read_gds(a.gds).top_level()[0]
maplayers={'met1':(68,20),'met2':(69,20),'met3':(70,20),'met4':(71,20),'via':(68,44),'via2':(69,44),'via3':(70,44)};pins={k:[] for k in maplayers};layer=None
for line in head.splitlines():
 m=re.search(r'\bLAYER\s+(\w+)\s*;',line)
 if m:layer=m[1]
 m=re.search(r'RECT\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)',line)
 if m and layer in pins:
  x1,y1,x2,y2=map(float,m.groups());pins[layer].append(gdstk.rectangle((x1,y1),(x2,y2)))
out=[head,'   OBS\n'];report={}
for key,(layer,datatype) in maplayers.items():
 actual=top.get_polygons(layer=layer,datatype=datatype)
 excess=gdstk.boolean(pins[key],actual,'not',precision=.001)
 assert sum(p.area() for p in excess)<.00001,(key,'LEF pin extends beyond real metal',sum(p.area() for p in excess))
 obs=gdstk.boolean(actual,pins[key],'not',precision=.001)
 missing=gdstk.boolean(actual,obs+pins[key],'not',precision=.001)
 assert sum(p.area() for p in missing)<.00001,(key,'missing')
 out.append(f'      LAYER {key} ;\n')
 for p in obs:
  # LEF POLYGON describes exact Manhattan polygons, including fractured holes.
  out.append('         POLYGON '+' '.join(f'{v:.3f}' for xy in p.points for v in xy)+' ;\n')
 report[key]={'gds_polygons':len(actual),'obstruction_polygons':len(obs),'missing_area_um2':sum(p.area() for p in missing),'pin_excess_area_um2':sum(p.area() for p in excess)}
 print(key,report[key],flush=True)
out.append(f'   END\nEND {name}\nEND LIBRARY\n');a.output.write_text(''.join(out));a.output.with_suffix('.coverage.json').write_text(json.dumps(report,indent=2)+'\n')
