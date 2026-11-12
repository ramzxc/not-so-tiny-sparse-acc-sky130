#!/usr/bin/env python3
"""Fail extraction when a full-circuit LVS input is missing or stale."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'macro/acc_hard_macro/manifest.json').read_text())
inputs = manifest['lvs_inputs']
assert len(inputs) == 4, 'Incomplete full LVS input manifest'
for name, expected in inputs.items():
    actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f'LVS source changed: {name}. Regenerate with scripts/build_lvs_spice.py.')
print('Full core and SRAM LVS source hashes verified.')
