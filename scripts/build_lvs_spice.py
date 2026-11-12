#!/usr/bin/env python3
"""Build LVS-only SPICE from the ICC2 powered netlist, without optimization.

Example: python3 scripts/build_lvs_spice.py --pdk /path/to/sky130A
Requires Yosys. Original GDS, simulation netlists, and SRAM SPICE are untouched.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'macro/acc_hard_macro'
SRAM = ROOT / 'memory/openram/generated/tt_sram_1rw_64x64_sky130'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def headers(text):
    text = re.sub(r'\n\s*\+', ' ', text)
    return {t[1]: t[2:] for line in text.splitlines()
            if (t := line.split()) and t[0].lower() == '.subckt'}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--pdk', type=Path, required=True)
    ap.add_argument('--yosys-command', default='yosys -s',
                    help='Command prefix; generated Yosys script path is appended')
    args = ap.parse_args()
    pdk = args.pdk.resolve()
    std_v = pdk / 'libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v'
    std_sp = pdk / 'libs.ref/sky130_fd_sc_hd/spice/sky130_fd_sc_hd.spice'
    source = CORE / 'acc_hard_macro.pg.v'
    sram_source = SRAM / 'tt_sram_1rw_64x64_sky130.lvs.sp'
    # Netgen and the PDK's standard-cell SPICE use bare micron W/L values.
    # This derivative is for LVS only, never a replacement simulation model.
    sram_text, unit_count = re.subn(
        r'\b([wl])=([0-9.eE+-]+)u\b', r'\1=\2',
        sram_source.read_text(), flags=re.I)
    cell_headers = headers(std_sp.read_text()) | headers(sram_text)
    text, supply_count = re.subn(r'\bsupply[01]\s+(VPWR|VGND)\s*;',
                                r'wire \1;', source.read_text())
    with tempfile.TemporaryDirectory(prefix='tt-lvs-') as tmp:
        tmp = Path(tmp)
        (tmp / 'input.v').write_text(text)
        commands = [
            f'read_verilog -lib -D USE_POWER_PINS -D FUNCTIONAL -D UNIT_DELAY= "{std_v}"',
            f'read_verilog -lib -D USE_POWER_PINS "{SRAM / "blackbox.v"}"',
            f'read_verilog "{tmp / "input.v"}"',
            'hierarchy -check -top acc_hard_macro',
            'flatten',
            f'write_json "{tmp / "design.json"}"',
        ]
        script = tmp / 'build.ys'
        script.write_text('\n'.join(commands) + '\n')
        subprocess.run(shlex.split(args.yosys_command) + [str(script)], check=True)
        design = json.loads((tmp / 'design.json').read_text())['modules']
    module = design['acc_hard_macro']
    nodes, ports, aliases = {}, [], []
    for name, port in module['ports'].items():
        # Netgen maps named Verilog bus connections to SPICE pins in declaration order.
        # ICC2 top ports are [7:0], so emit their MSB first.
        for i in reversed(range(len(port['bits']))):
            bit = port['bits'][i]
            label = name if len(port['bits']) == 1 else f'{name}[{i + port.get("offset", 0)}]'
            ports.append(label)
            if bit in nodes:
                aliases.append((label, nodes[bit]))
            else:
                nodes[bit] = label

    # Canonicalize each physical node independently of bus declaration order.
    # Zero-ohm port aliases preserve every external pin name.
    groups = collections.defaultdict(list)
    for name, port in module['ports'].items():
        for i, bit in enumerate(port['bits']):
            label = name if len(port['bits']) == 1 else f'{name}[{i + port.get("offset", 0)}]'
            groups[bit].append(label)
    nodes = {bit: min(names) for bit, names in groups.items()}
    aliases = [(name, nodes[bit]) for bit, names in groups.items()
               for name in sorted(names) if name != nodes[bit]]

    def node(bit):
        if not isinstance(bit, int):
            raise ValueError(f'Unexpected constant {bit}; require physical tie-cell connectivity')
        return nodes.get(bit, f'n{bit}')

    lines = ['* LVS ONLY: ICC2 powered netlist connectivity, no logic optimization.',
             '* W/L convention in library models: microns.',
             '.subckt acc_hard_macro ' + ' '.join(ports)]
    for i, (a, b) in enumerate(aliases):
        lines.append(f'Ralias{i} {a} {b} 0')
    counts, dangling = collections.Counter(), collections.Counter()
    connectivity = []
    for i, (name, cell) in enumerate(module['cells'].items()):
        kind = cell['type']
        if kind == '$scopeinfo':  # Yosys hierarchy metadata; no circuit device
            continue
        pins = []
        for pin in cell_headers[kind]:
            match = re.fullmatch(r'(.+)\[(\d+)\]', pin)
            key, index = (match[1], int(match[2])) if match else (pin, 0)
            if key not in cell['connections']:
                if design[kind]['ports'][key]['direction'] != 'output':
                    raise ValueError(f'Missing non-output connection: {name}.{pin}')
                pins.append(f'nc_{i}_{pin}')
                dangling[f'{kind}.{pin}'] += 1
            else:
                pins.append(node(cell['connections'][key][index]))
        # Emit direct canonical bit connectivity: no Verilog alias assignments.
        lines.append(f'X{i} ' + ' '.join(pins) + ' ' + kind)
        connectivity.append((kind, pins))
        counts[kind] += 1
    lines.append('.ends acc_hard_macro')
    emitted = '\n'.join(lines) + '\n'
    # Independently parse emitted instances and verify exact pin order/topology.
    roundtrip = [(t[-1], t[1:-1]) for line in emitted.splitlines()
                 if (t := line.split()) and t[0].startswith('X')]
    assert roundtrip == connectivity
    assert counts['tt_sram_1rw_64x64_sky130'] == 1
    assert len(ports) == 45
    core_output = CORE / 'acc_hard_macro.lvs.spice'
    core_output.write_text(emitted)
    with tempfile.TemporaryDirectory(prefix='tt-lvs-alias-') as tmp:
        canonical = Path(tmp) / 'core.spice'
        subprocess.run([sys.executable, str(ROOT / 'scripts/normalize_lvs_aliases.py'),
                        str(core_output), str(canonical)], check=True)
        core_output.write_bytes(canonical.read_bytes())
    (CORE / 'sram.lvs_micron.spice').write_text(
        '* LVS ONLY: W/L in microns, matching Magic scale-off and PDK SPICE.\n' + sram_text)
    report = {
        'source_powered_netlist_sha256': digest(source),
        'source_sram_spice_sha256': digest(sram_source),
        'standard_cell_spice_sha256': digest(std_sp),
        'gds_sha256': digest(CORE / 'acc_hard_macro.gds'),
        'supply_declarations_represented_as_connected_wires': supply_count,
        'sram_W_L_micron_suffixes_normalized': unit_count,
        'top_ports': len(ports), 'port_aliases': aliases,
        'physical_instances': sum(counts.values()), 'cells_by_type': dict(sorted(counts.items())),
        'unconnected_output_pins': dict(sorted(dangling.items())),
        'emitted_connectivity_roundtrip': 'PASS',
        'optimization_passes': [],
    }
    (CORE / 'lvs_source_validation.json').write_text(json.dumps(report, indent=2) + '\n')
    manifest_path = CORE / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['lvs_inputs'] = {
        'macro/acc_hard_macro/acc_hard_macro.pg.v': digest(source),
        'memory/openram/generated/tt_sram_1rw_64x64_sky130/tt_sram_1rw_64x64_sky130.lvs.sp': digest(sram_source),
        'macro/acc_hard_macro/acc_hard_macro.lvs.spice': digest(core_output),
        'macro/acc_hard_macro/sram.lvs_micron.spice': digest(CORE / 'sram.lvs_micron.spice'),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Generated {sum(counts.values())} physical instances; {len(ports)} ports.')


if __name__ == '__main__':
    main()
