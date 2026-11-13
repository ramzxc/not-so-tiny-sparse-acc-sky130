#!/usr/bin/env python3
"""Read exported ICC2 DEF/LEFs with OpenROAD; never run placement or routing.

PDK_ROOT=/path/to/pdk openroad -exit -python scripts/extract_core_summary.py
Optional CORE_DEF overrides manifest.source_run/acc_hard_macro.def.
Produces a small, source-hashed CI input instead of committing the whole DEF.
"""
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from actions_summary import core_cells, PREFIX


def rectangle(box):
    return (box.xMin(), box.yMin(), box.xMax(), box.yMax())


def union_area(rects):
    """Exact rectangle union in integer DEF database units (no double counting)."""
    xs = sorted({x for x0, _, x1, _ in rects for x in (x0, x1)})
    area = 0
    for left, right in zip(xs, xs[1:]):
        intervals = sorted((y0, y1) for x0, y0, x1, y1 in rects if x0 < right and x1 > left)
        end = None
        height = 0
        for lo, hi in intervals:
            height += max(0, hi - max(lo, end if end is not None else lo))
            end = max(hi, end if end is not None else hi)
        area += (right - left) * height
    return area


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    from openroad import Tech, Design

    folder = ROOT / 'macro/acc_hard_macro'
    manifest = json.loads((folder / 'manifest.json').read_text())
    source = Path(os.environ.get('CORE_DEF', ROOT / manifest['source_run'] / 'acc_hard_macro.def'))
    pdk = Path(os.environ['PDK_ROOT']) / 'sky130A/libs.ref/sky130_fd_sc_hd'
    lefs = [pdk / 'techlef/sky130_fd_sc_hd__nom.tlef', pdk / 'lef/sky130_fd_sc_hd.lef',
            ROOT / 'memory/openram/generated/tt_sram_1rw_64x64_sky130/tt_sram_1rw_64x64_sky130.lef']
    # The DEF and powered netlist must come from the same export package.
    if digest(source.with_suffix('.pg.v')) != digest(folder / 'acc_hard_macro.pg.v'):
        raise ValueError('DEF export package does not match the submitted powered netlist')
    tech = Tech()
    design = Design(tech)
    for lef in lefs:
        tech.readLef(str(lef))
    design.readDef(str(source))
    block = tech.getDB().getChip().getBlock()
    if block.getName() != 'acc_hard_macro':
        raise ValueError('Unexpected DEF top')
    counts = Counter(i.getMaster().getName() for i in block.getInsts())
    if counts != core_cells(ROOT):
        raise ValueError('DEF cell inventory differs from the submitted physical netlist')
    units = block.getDbUnitsPerMicron()
    rows = [rectangle(row.getBBox()) for row in block.getRows()]
    blocked = [rectangle(b.getBBox()) for b in block.getBlockages()]
    areas = Counter()
    for inst in block.getInsts():
        master = inst.getMaster()
        name = master.getName()
        area = master.getWidth() * master.getHeight()
        if name.startswith(PREFIX):
            category = 'fill' if name.startswith(PREFIX + 'fill_') else 'tap' if name.startswith(PREFIX + 'tap') else 'functional'
            areas[category] += area
        else:
            areas['macro'] += area
            x0, y0, x1, y1 = rectangle(inst.getBBox())
            if halo := inst.getHalo():
                left, bottom, right, top = rectangle(halo)
                x0, y0, x1, y1 = x0-left, y0-bottom, x1+right, y1+top
            blocked.append((x0, y0, x1, y1))
    clipped = []
    for a, b, c, d in rows:
        for x0, y0, x1, y1 in blocked:
            rect = (max(a, x0), max(b, y0), min(c, x1), min(d, y1))
            if rect[0] < rect[2] and rect[1] < rect[3]:
                clipped.append(rect)
    row_area = union_area(rows)
    available = row_area - union_area(clipped)
    if available <= 0:
        raise ValueError('No available row area')
    lengths = Counter()
    for net in block.getNets():
        if net.getSigType() not in ('POWER', 'GROUND') and net.getWire():
            lengths[str(net.getSigType()).lower()] += net.getWire().getLength() / units
    assets = ['acc_hard_macro.gds', 'acc_hard_macro.lef', 'acc_hard_macro.pg.v', 'acc_hard_macro.lvs.spice']
    result = {
        'schema': 1,
        'source_def': str(source.relative_to(ROOT)),
        'source_def_sha256': digest(source),
        'source_lefs_sha256': {p.name: digest(p) for p in lefs},
        'submitted_assets_sha256': {name: digest(folder / name) for name in assets},
        'method': 'OpenROAD readDef; dbWire.getLength for non-PG regular NETS; LEF master area; union of DEF rows minus macro+halo and placement blockages',
        'wire_exclusions': 'SRAM internal wiring, POWER/GROUND, SPECIALNETS shapes (including signal patches), via vertical lengths and pin metal',
        'cell_count': dict(sorted(counts.items())),
        'area_um2': {**{k: v / units**2 for k, v in areas.items()},
                     'rows': row_area / units**2, 'available_rows': available / units**2},
        'utilization_pct': {
            'excluding_fill_tap': 100 * areas['functional'] / available},
        'wirelength_um': dict(lengths),
        'wirelength_total_um': sum(lengths.values()),
    }
    (folder / 'physical_summary.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
