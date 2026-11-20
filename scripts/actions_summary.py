#!/usr/bin/env python3
"""Read-only Actions summaries for either RTL+SRAM or a prebuilt-core wrapper.

Only add the packaged core inventory when the routed DEF actually contains
acc_hard_macro; the RTL flow already includes the core's standard cells.
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
    for name in ('acc_hard_macro.v', 'acc_hard_macro.lvs.spice'):
        path = folder / name
        key = path.relative_to(root).as_posix()
        if hashlib.sha256(path.read_bytes()).hexdigest() != manifest['lvs_inputs'][key]:
            raise ValueError(f'Stale core cell inventory: {name}')
    text = (folder / 'acc_hard_macro.lvs.spice').read_text()
    if len(re.findall(r'(?im)^\.subckt\b', text)) != 1:
        raise ValueError('Expected one flattened core subcircuit')
    return Counter(line.split()[-1] for line in text.splitlines() if line.startswith('X'))


def core_physical(root):
    folder = root / 'macro/acc_hard_macro'
    result = json.loads((folder / 'physical_summary.json').read_text())
    if result['schema'] != 1:
        raise ValueError('Unsupported core physical-summary schema')
    for name, expected in result['submitted_assets_sha256'].items():
        if hashlib.sha256((folder / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f'Stale core physical summary: {name}; rerun scripts/extract_core_summary.py')
    if result['cell_count'] != core_cells(root):
        raise ValueError('Core physical summary inventory mismatch')
    return result


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
    defs = list((run / 'final/def').glob('*.def'))
    if len(defs) != 1:
        raise ValueError('Expected one final DEF for flow identification')
    inventory = def_cells(defs[0].read_text())
    cores = inventory.get('acc_hard_macro', 0)
    if cores == 0:
        # These are the routed RTL design's own metrics. Do not double-count
        # the independently synthesized ICC2 candidate published in macro/.
        utilization = float(metrics['design__instance__utilization__stdcell']) * 100
        table(['OpenROAD standard-cell utilisation (%)', 'Wire length (um)'], [
            [f'{utilization:.2f}', metrics['route__wirelength']],
        ])
        print('RTL + SRAM flow. OpenROAD utilisation excludes macro area from '
              'the core-area denominator; it is not the stricter remaining-row '
              'capacity after all placement keepouts. Wire length is this routed '
              'design only, excluding SRAM internal wiring and PG. The separately '
              'published ICC2 candidate is not added.\n')
        return
    if cores != 1:
        raise ValueError('Expected at most one prebuilt accelerator core')
    core = core_physical(ROOT)
    wrapper_wire = metrics.get('route__wirelength', metrics.get('detailedroute__route__wirelength'))
    length = f"{float(wrapper_wire) + core['wirelength_total_um']:.3f}" if wrapper_wire is not None else 'N/A'
    table(['Utilisation (%)', 'Wire length (um)'], [
        [f"{core['utilization_pct']['excluding_fill_tap']:.2f}", length],
    ])
    print('Utilisation: core standard-cell area excluding fill/tap ÷ DEF row area '
          'remaining after SRAM, halo and placement blockages; calculated from final DEF, '
          'not the original global-placement log value. Wire length: core + wrapper '
          'regular signal/clock routes; excludes SRAM internal wiring, PG, SPECIALNETS '
          'patches and via vertical lengths. Sources: source-hashed core physical_summary.json '
          'and wrapper final/metrics.json.\n')


def cells(root, run, categories_path):
    print('# Cell usage by Category\n')
    defs = list((run / 'final/def').glob('*.def'))
    if len(defs) != 1:
        print('Unavailable: expected one final wrapper DEF.\n')
        return
    wrapper = def_cells(defs[0].read_text())
    cores = wrapper.pop('acc_hard_macro', 0)
    if cores not in (0, 1):
        raise ValueError('Expected at most one prebuilt accelerator core')
    inventory = wrapper + core_cells(root) if cores else wrapper
    categories = json.loads(categories_path.read_text())
    grouped = {}
    for cell, count in inventory.items():
        if not cell.startswith(PREFIX):
            continue  # SRAM is not a standard cell.
        base = cell[len(PREFIX):].rsplit('_', 1)[0]
        index = categories['map'].get(base)
        category = categories['categories'][index] if index is not None else 'Unclassified'
        if category in ('Fill', 'Tap'):
            continue
        group = grouped.setdefault(category, {'count': 0, 'cells': set()})
        group['count'] += count
        group['cells'].add(base)
    def cell_link(name):
        return f'[{name}](https://skywater-pdk.readthedocs.io/en/main/contents/libraries/sky130_fd_sc_hd/cells/{name}/README.html)'

    table(['Category', 'Cells', 'Count'], [
        [category, ' '.join(cell_link(name) for name in sorted(data['cells'])), data['count']]
        for category, data in sorted(grouped.items(), key=lambda item: item[1]['count'], reverse=True)
    ])
    print(f"## {sum(data['count'] for data in grouped.values())} total cells (excluding fill and tap cells)\n")


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
