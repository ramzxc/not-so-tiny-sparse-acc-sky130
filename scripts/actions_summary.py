#!/usr/bin/env python3
"""Read-only Actions summaries for the routed wrapper and hardened core.

LibreLane metrics describe the wrapper: they do not include routing inside the
hard macro. Count core physical cells from the flattened, hash-checked LVS
source generated from ICC2's powered netlist (including filler/tap cells).
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'sky130_fd_sc_hd__'


def def_cells(text):
    section = re.search(r'(?ms)^COMPONENTS\s+(\d+)\s*;(.*?)^END COMPONENTS', text)
    if section is None:
        raise ValueError('Missing DEF COMPONENTS section')
    cells = Counter(re.findall(r'(?m)^\s*-\s+\S+\s+(\S+)', section[2]))
    if sum(cells.values()) != int(section[1]):
        raise ValueError('DEF component count mismatch')
    return cells


def core_cells(root):
    folder = root / 'macro/acc_hard_macro'
    manifest = json.loads((folder / 'manifest.json').read_text())
    # Both the original physical netlist and generated flattened inventory must
    # still match the provenance used to build the full-circuit LVS source.
    for name in ('acc_hard_macro.pg.v', 'acc_hard_macro.lvs.spice'):
        path = folder / name
        key = path.relative_to(root).as_posix()
        if hashlib.sha256(path.read_bytes()).hexdigest() != manifest['lvs_inputs'][key]:
            raise ValueError(f'Stale core cell inventory: {name}')
    text = (folder / 'acc_hard_macro.lvs.spice').read_text()
    if len(re.findall(r'(?im)^\.subckt\b', text)) != 1:
        raise ValueError('Expected one flattened core subcircuit')
    return Counter(line.split()[-1] for line in text.splitlines() if line.startswith('X'))


def table(headers, rows):
    print('| ' + ' | '.join(headers) + ' |')
    print('|' + '|'.join('---' for _ in headers) + '|')
    for row in rows:
        print('| ' + ' | '.join(map(str, row)) + ' |')
    print()


def routing(run):
    path = run / 'final/metrics.json'
    print('# Routing stats\n')
    if not path.exists():
        print('Unavailable: this run has no final/metrics.json.\n')
        return
    metrics = json.loads(path.read_text())

    def value(*keys, scale=1):
        for key in keys:
            if metrics.get(key) is not None:
                return f'{float(metrics[key]) * scale:,.3f}'
        return 'N/A (not reported)'

    table(['Metric', 'Value', 'Scope'], [
        ['Routed wire length (µm)', value('route__wirelength', 'detailedroute__route__wirelength'), 'Wrapper only'],
        ['Instance utilization (%)', value('design__instance__utilization', scale=100), 'Wrapper, including macro footprint'],
        ['Standard-cell utilization (%)', value('design__instance__utilization__stdcell', scale=100), 'Wrapper standard cells; LibreLane denominator'],
        ['Die area (µm²)', value('design__die__area'), 'Tiny Tapeout wrapper'],
        ['Macro footprint area (µm²)', value('design__instance__area__macros'), 'Includes core logic and SRAM footprint'],
    ])
    print('Source: `runs/wokwi/final/metrics.json`. Utilization is the reported fraction × 100. '
          'Macro footprint is not the sum of standard-cell areas. '
          'Core/SRAM internal wire length is not reported by this wrapper run; '
          'the wrapper wire length is **not** the whole-chip wire length.\n')


def cells(root, run, categories_path):
    print('# Cell usage\n')
    defs = list((run / 'final/def').glob('*.def'))
    if len(defs) != 1:
        print('Unavailable: expected one final wrapper DEF.\n')
        return
    wrapper = def_cells(defs[0].read_text())
    if wrapper.pop('acc_hard_macro', 0) != 1:
        raise ValueError('Expected exactly one acc_hard_macro in wrapper DEF')
    core = core_cells(root)
    categories = json.loads(categories_path.read_text())

    def category(cell):
        if not cell.startswith(PREFIX):
            return 'Macro (not expanded)'
        base = cell[len(PREFIX):].rsplit('_', 1)[0]
        index = categories['map'].get(base)
        return categories['categories'][index] if index is not None else 'Unclassified standard cell'

    grouped = []
    for inventory in (wrapper, core):
        counts = Counter()
        for cell, count in inventory.items():
            counts[category(cell)] += count
        grouped.append(counts)
    table(['Category', 'Wrapper', 'Core', 'Total'], [
        [cat, grouped[0][cat], grouped[1][cat], grouped[0][cat] + grouped[1][cat]]
        for cat in sorted(set(grouped[0]) | set(grouped[1]))
    ])
    std = [sum(count for cell, count in inv.items() if cell.startswith(PREFIX)) for inv in (wrapper, core)]
    active = [sum(count for cell, count in inv.items()
                  if cell.startswith(PREFIX) and category(cell) not in ('Fill', 'Tap'))
              for inv in (wrapper, core)]
    table(['Count', 'Wrapper', 'Core', 'Total'], [
        ['All standard cells, including fill/tap', *std, sum(std)],
        ['Standard cells excluding fill/tap', *active, sum(active)],
    ])
    print('Sources: final wrapper DEF and hash-checked `acc_hard_macro.lvs.spice`, '
          'generated from ICC2 `acc_hard_macro.pg.v`. The core container is expanded '
          'once, not counted again. SRAM remains one macro; its transistors are not '
          'standard cells. Fill/tap cells are shown separately.\n')
    print('<details><summary>Cell usage by master</summary>\n')
    table(['Cell master', 'Wrapper', 'Core', 'Total'], [
        [cell, wrapper[cell], core[cell], wrapper[cell] + core[cell]]
        for cell in sorted(set(wrapper) | set(core))
    ])
    print('</details>\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('section', choices=['routing', 'cells'])
    parser.add_argument('--run', type=Path, default=ROOT / 'runs/wokwi')
    parser.add_argument('--categories', type=Path, default=ROOT / 'tt/tech/sky130A/categories.json')
    args = parser.parse_args()
    if args.section == 'routing':
        routing(args.run)
    else:
        cells(ROOT, args.run, args.categories)


if __name__ == '__main__':
    main()
