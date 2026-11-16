#!/usr/bin/env python3
"""Check the single-supply core before power-on functional equivalence.

Uses the hash-checked, connectivity-preserving LVS source and official PDK
SPICE pin order. This does not replace extracted-GDS LVS or electrical checks.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

from build_lvs_spice import headers

ROOT = Path(__file__).resolve().parents[1]


def check(root, pdk):
    folder = root / 'macro/acc_hard_macro'
    manifest = json.loads((folder / 'manifest.json').read_text())
    for name, expected in manifest['lvs_inputs'].items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f'Stale LVS source: {name}; regenerate before checking PG')
    text = (folder / 'acc_hard_macro.v').read_text()
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    supplies = re.findall(r'\bsupply([01])\s+([^;]+);', text)
    if not supplies or any((value, name.strip()) not in
                           [('1', 'VPWR'), ('0', 'VGND')] for value, name in supplies):
        raise ValueError('Only supply1 VPWR / supply0 VGND are allowed')
    std = pdk / 'libs.ref/sky130_fd_sc_hd/spice/sky130_fd_sc_hd.spice'
    pin_orders = headers(std.read_text()) | headers((folder / 'sram.lvs_micron.spice').read_text())
    expected_pg = {'VPWR': 'VPWR', 'VPB': 'VPWR', 'VGND': 'VGND', 'VNB': 'VGND',
                   'vccd1': 'VPWR', 'vssd1': 'VGND'}
    cells = pins = 0
    for line in (folder / 'acc_hard_macro.lvs.spice').read_text().splitlines():
        if not line.startswith('X'):
            continue
        instance, *nodes, kind = line.split()
        order = pin_orders[kind]
        if len(nodes) != len(order):
            raise ValueError(f'Pin-count mismatch: {instance} {kind}')
        checked = 0
        for pin, node in zip(order, nodes):
            if pin in expected_pg:
                if node != expected_pg[pin]:
                    raise ValueError(f'Wrong PG connection: {instance} {kind}.{pin} = {node}')
                checked += 1
        if checked not in (2, 4):
            raise ValueError(f'Incomplete power-pin definition: {kind}')
        cells += 1
        pins += checked
    if not cells:
        raise ValueError('No physical cells checked')
    return cells, pins


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pdk', type=Path, required=True, help='Path to sky130A')
    args = parser.parse_args()
    cells, pins = check(ROOT, args.pdk)
    print(f'PG connectivity PASS: {cells} physical instances, {pins} supply/well pins')
