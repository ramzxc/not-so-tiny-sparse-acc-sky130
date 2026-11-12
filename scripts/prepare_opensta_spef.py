#!/usr/bin/env python3
"""Escape ICC2 physical-cell names for OpenSTA without changing RC data."""
from pathlib import Path
import gzip
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]
MACRO = ROOT / 'macro/acc_hard_macro'
SOURCE = MACRO / 'acc_hard_macro.sky130_nominal_25.spef'
OUTPUT = MACRO / 'acc_hard_macro.opensta.spef.gz'

def main():
    original = SOURCE.read_bytes()
    lines = original.splitlines(keepends=True)
    inside = False
    count = 0
    for i, line in enumerate(lines):
        if line.strip() == b'*NAME_MAP':
            inside = True
            continue
        if inside and line.startswith(b'*PORTS'):
            inside = False
        if inside and re.match(rb'^\*\d+\s+', line) and b'!' in line:
            assert b'\\!' not in line, 'Already escaped source name'
            lines[i] = line.replace(b'!', b'\\!')
            count += 1
    result = b''.join(lines)
    assert result.replace(b'\\!', b'!') == original, 'Unexpected change outside name escaping'
    OUTPUT.write_bytes(gzip.compress(result, mtime=0))
    report = {'source': SOURCE.name, 'output': OUTPUT.name,
              'escaped_name_map_entries': count,
              'source_sha256': hashlib.sha256(original).hexdigest(),
              'decoded_output_sha256': hashlib.sha256(result).hexdigest(),
              'rc_sections_unchanged': True}
    (MACRO / 'opensta_spef_conversion.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
