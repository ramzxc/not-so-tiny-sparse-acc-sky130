"""Select SRAM NFET model names from the installed SKY130 extraction rules.

OpenRAM issue #337: the narrow device exists only in some PDK revisions.
https://github.com/VLSIDA/OpenRAM/issues/337
This is source-model selection, not an LVS device-equivalence waiver.
"""
from decimal import Decimal
import re


def narrow_nfet_rule(tech_text):
    text = tech_text.replace('\\\n', ' ')
    declaration = re.search(
        r'(?m)^\s*device\s+msubcircuit\s+sky130_fd_pr__special_nfet_01v8\s+[^\n]+', text)
    if declaration is None:
        return {'model': None, 'width_lt_um': None}
    limit = re.search(r'\bw<([0-9.]+)', declaration[0])
    if limit is None:
        raise ValueError('Unknown narrow-NFET extraction rule; refusing to guess')
    return {'model': 'sky130_fd_pr__special_nfet_01v8', 'width_lt_um': limit[1]}


def select_nfet_models(spice, rule):
    if rule['model'] is None:
        return spice, 0
    count = 0
    lines = []
    for line in spice.splitlines(keepends=True):
        tokens = line.split()
        if tokens and tokens[0][0].upper() == 'X' and 'sky130_fd_pr__nfet_01v8' in tokens:
            width = re.search(r'\bw=([^\s]+)', line, flags=re.I)
            if width is None:
                raise ValueError('NFET without explicit width: ' + line)
            if Decimal(width[1]) < Decimal(rule['width_lt_um']):
                line = line.replace('sky130_fd_pr__nfet_01v8', rule['model'])
                count += 1
        lines.append(line)
    return ''.join(lines), count
