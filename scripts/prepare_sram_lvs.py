#!/usr/bin/env python3
"""Convert OpenRAM W/L to Magic's micron convention and select active PDK models."""
import os
import argparse
import hashlib
import json
from pathlib import Path
import re
from sky130_lvs_models import narrow_nfet_rule, select_nfet_models
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--core', action='store_true', help='Prepare the hardened core SRAM source after checking its input manifest')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
manifest_path = root / 'macro/acc_hard_macro/manifest.json'
if args.core:
    manifest = json.loads(manifest_path.read_text())
    for name, expected in manifest['lvs_inputs'].items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
            raise SystemExit('LVS input changed before model preparation: ' + name)
folder = root / 'memory/openram/generated/tt_sram_1rw_64x128_buffered_sky130'
tech = Path(os.environ['MAGIC_TECH']) if os.environ.get('MAGIC_TECH') else Path(os.environ['PDK_ROOT']) / os.environ.get('PDK','sky130A') / 'libs.tech/magic/sky130A.tech'
text = (folder / 'tt_sram_1rw_64x128_buffered_sky130.lvs.sp').read_text()
text = re.sub(r'\b([wl])=([0-9.]+)u\b', r'\1=\2', text, flags=re.I)
rule = narrow_nfet_rule(tech.read_text())
text, count = select_nfet_models(text, rule)
if not args.core:
    # Netgen binds Verilog concatenations in the SPICE declaration order.
    # Match the descending bus declarations in blackbox.v. Only reorder the
    # top-level formal pins; all named internal nodes and devices stay intact.
    pattern = r'(?im)^\.subckt tt_sram_1rw_64x128_buffered_sky130\s*\n(?:\+[^\n]*\n)+'
    match = re.search(pattern, text)
    if match is None:
        raise SystemExit('Missing SRAM top-level SPICE port declaration')
    header = match[0].replace('\n+', ' ').split()
    pins = header[2:]
    for bus, width in [('din0', 65), ('addr0', 7), ('dout0', 65)]:
        old = [f'{bus}[{i}]' for i in range(width)]
        start = pins.index(old[0])
        if pins[start:start + width] != old:
            raise SystemExit('Unexpected SRAM bus order: ' + bus)
        pins[start:start + width] = old[::-1]
    header = header[:2] + pins
    replacement = ' '.join(header[:2]) + '\n'
    replacement += ''.join('+ ' + ' '.join(pins[i:i+8]) + '\n'
                           for i in range(0, len(pins), 8))
    text = text[:match.start()] + replacement + text[match.end():]
    text = '\n'.join(line.rstrip() for line in text.splitlines()) + '\n'
output = (root / 'macro/acc_hard_macro' if args.core else folder) / 'sram.lvs_micron.spice'
header = '* LVS ONLY: W/L in microns, matching Magic scale-off and PDK SPICE.\n' if args.core else '* Generated from OpenRAM LVS source for the active PDK.\n'
output.write_text(header + text)
print(f'SRAM LVS source prepared; narrow NFETs selected: {count}')

if args.core:
    manifest['lvs_inputs'][str(output.relative_to(root))] = hashlib.sha256(output.read_bytes()).hexdigest()
    manifest['lvs_nfet_rule'] = rule
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
