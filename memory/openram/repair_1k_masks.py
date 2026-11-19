"""Repair the 1 KiB macro's mask spacing; retain all original cell geometry.

Requires gdstk. Input is the hash-pinned original 1 KiB macro.
SKY130 periphery rules nsd.2/psd.2/npc.2 require merging close masks.
This geometry-specific repair MUST be followed by Magic/KLayout DRC and LVS.
"""
import argparse, hashlib, json
from pathlib import Path
import gdstk
p=argparse.ArgumentParser(description=__doc__)
p.add_argument("input",type=Path);p.add_argument("output",type=Path)
a=p.parse_args()
assert hashlib.sha256(a.input.read_bytes()).hexdigest()=="3c374d1a81f40c6227062c09346a532210cadfdd48f88916da92ba205c83d5e8", "Unexpected input geometry"
lib=gdstk.read_gds(a.input);top=lib.top_level()[0];stats={}
for layer,datatype,spacing in [(93,44,.38),(94,20,.38),(95,20,.27)]:
    original=top.get_polygons(layer=layer,datatype=datatype)
    grown=gdstk.offset(original,spacing/2,join="miter",precision=.001,use_union=True)
    closed=gdstk.offset(grown,-spacing/2,join="miter",precision=.001,use_union=True)
    merged=gdstk.boolean(original,closed,"or",precision=.001,layer=layer,datatype=datatype)
    additions=gdstk.boolean(merged,original,"not",precision=.001,layer=layer,datatype=datatype)
    top.add(*additions)
    stats[str((layer,datatype))]={"added_area_um2":sum(p.area() for p in additions),"minimum_spacing_um":spacing}
# Same two control-logic junctions as the 512 B macro, translated +26.860 um in Y.
# Coordinates are resolved from the 1 KiB control/inverter hierarchy.
for cx,cy,down,up in [(32.755,90.145,.25,.38),(41.105,76.005,.38,.25)]:
    top.add(gdstk.rectangle((round(cx-.38,3),round(cy-down,3)),(round(cx+.40,3),round(cy+up,3)),layer=94,datatype=20))
overlap = gdstk.boolean(
    gdstk.boolean(top.get_polygons(layer=93,datatype=44),
                  top.get_polygons(layer=94,datatype=20), "and", precision=.001),
    top.get_polygons(layer=65,datatype=20), "and", precision=.001)
assert not overlap, "NSDM and PSDM overlap over active"
a.output.parent.mkdir(parents=True,exist_ok=True)
lib.write_gds(a.output)
a.output.with_suffix(".mask_repair.json").write_text(json.dumps(stats,indent=2)+"\n")
