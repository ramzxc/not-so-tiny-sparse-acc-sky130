#!/usr/bin/env python3
"""Check current QSPI RTL with explicit round-trip delays; no synthesis required."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, default=Path('/tmp/acc-qspi-timing'))
    args = parser.parse_args()
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    rtl = ROOT / 'src/rtl/qspi_ctrl.v'
    results = []
    for name, half, forward, back, tco in [
        ('ideal', 10, 0, 0, 0),
        ('short', 10, 4, 4, 5.5),
        ('tt_measured_sum_scenario', 10, 10, 10, 5.5),
        ('extra_margin_scenario', 10, 12.5, 12.5, 5.5),
        ('slow_core_scenario', 20, 10, 10, 5.5),
    ]:
        binary = build / name
        cmd = ['iverilog', '-g2012', '-s', 'tb_qspi_board_timing', '-o', str(binary)]
        for key, value in [('HALF', half), ('OUT_DELAY', forward), ('IN_DELAY', back), ('TCO', tco)]:
            cmd.append(f'-Ptb_qspi_board_timing.{key}={value}')
        cmd += [str(ROOT / 'test/tb_qspi_board_timing.sv'), str(rtl),
                str(ROOT / 'test/qspi_psram_model.sv')]
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        run = subprocess.run(['vvp', str(binary)], capture_output=True, text=True)
        log = run.stdout + run.stderr
        (build / f'{name}.log').write_text(log)
        match = re.search(r'elapsed_ns=([\d.]+) checked=(\d+) errors=(\d+)', log)
        if run.returncode or not match:
            raise RuntimeError(log)
        elapsed, checked, errors = float(match[1]), int(match[2]), int(match[3])
        # The original directed sequence took 6564 core cycles, including reset.
        if (checked, errors) != (480, 0) or elapsed != 6564 * 2 * half:
            raise RuntimeError(f'Incorrect result or changed transaction schedule: {log}')
        results.append(dict(scenario=name, core_mhz=500 / half, forward_ns=forward,
                            return_ns=back, tco_ns=tco, checked=checked, errors=errors,
                            elapsed_ns=elapsed))
        print(name, log.strip())
    (build / 'results.json').write_text(json.dumps(dict(
        rtl_sha256=hashlib.sha256(rtl.read_bytes()).hexdigest(), results=results), indent=2) + '\n')


if __name__ == '__main__':
    main()
