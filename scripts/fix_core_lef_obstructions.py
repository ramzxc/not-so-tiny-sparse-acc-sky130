#!/usr/bin/env python3
"""Trim only empty M1 margins from the macro OBS, verified against actual GDS."""
from pathlib import Path
import hashlib
import json
import re
import gdstk

root = Path(__file__).resolve().parents[1]
macro = root / 'macro/acc_hard_macro'
lef_path = macro / 'acc_hard_macro.lef'
gds_path = macro / 'acc_hard_macro.gds'
text = lef_path.read_text()
original = text
lib = gdstk.read_gds(gds_path)
core = next(c for c in lib.cells if c.name == 'acc_hard_macro')
metal = core.get_polygons(layer=68, datatype=20)
assert metal, 'No real M1 geometry found'
ymin = min(p.bounding_box()[0][1] for p in metal)
ymax = max(p.bounding_box()[1][1] for p in metal)
ymin, ymax = round(ymin, 6), round(ymax, 6)
removed = []
changes = []

def trim(match):
    header, body = match.groups()
    assert 'POLYGON' not in body, 'Unexpected M1 OBS polygon'
    def rect(m):
        x1, y1, x2, y2 = map(float, m[1].split())
        low, high = max(y1, ymin), min(y2, ymax)
        before = gdstk.rectangle((x1, y1), (x2, y2))
        after = [gdstk.rectangle((x1, low), (x2, high))] if high > low else []
        removed.extend(gdstk.boolean([before], after, 'not', precision=0.001))
        if (low, high) != (y1, y2):
            changes.append({'before': [x1,y1,x2,y2], 'after': [x1,low,x2,high]})
        return f'RECT {x1:g} {low:g} {x2:g} {high:g} ;' if after else ''
    return header + re.sub(r'RECT\s+([^;]+);', rect, body)

# Restrict edits to obstruction sections, never port definitions.
start = text.index('  OBS\n')
prefix, obs = text[:start], text[start:]
obs = re.sub(r'^(    LAYER met1(?: SPACING 0)? ;)(.*?)(?=^    LAYER|^  END)',
             trim, obs, flags=re.S | re.M)
assert not gdstk.boolean(removed, metal, 'and', precision=0.001), \
    'Refusing to expose actual M1 metal as a routing gap'
text = prefix + obs
lef_path.write_text(text)
sha = lambda b: hashlib.sha256(b).hexdigest()
report = {'input_lef_sha256': sha(original.encode()), 'output_lef_sha256': sha(text.encode()),
          'gds_sha256': sha(gds_path.read_bytes()), 'gds_metal1_y_bounds_um': [ymin,ymax],
          'metal1_polygons_checked': len(metal), 'changed_obstructions': changes,
          'removed_OBS_intersection_with_actual_M1': 'EMPTY',
          'pin_definitions_unchanged': prefix == original[:start],
          'note': 'Only empty top/bottom M1 abstract margins removed. GDS and other layers unchanged.'}
(macro/'lef_obstruction_validation.json').write_text(json.dumps(report,indent=2)+'\n')
manifest_path = macro/'manifest.json'
m = json.loads(manifest_path.read_text());m['sha256']['acc_hard_macro.lef']=sha(text.encode())
m['lef_obstructions']='Removed only empty M1 margins after checking all GDS M1 geometry; pins and GDS unchanged. Regenerate with scripts/fix_core_lef_obstructions.py.'
manifest_path.write_text(json.dumps(m,indent=2)+'\n')
print(json.dumps(report,indent=2))
