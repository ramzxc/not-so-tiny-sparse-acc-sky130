#!/usr/bin/env python3
"""Measure actual adjacent Bishop frames; project FIFO deadlines from RTL service times.

No synthesis. Independent warm-started frame simulations are not a live streaming
RTL test. Each frame uses the exact prior reference state, and all states/output
are checked. Empty queue at each selected window makes the queue test favorable.
"""
import argparse
import hashlib
import json
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from compact_sram import compact_sram
from prepare_fp8_network import build

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/stream_deadline'


def prepare(dataset, step):
    original = Path(build(dataset, step, consumer=True, stream=True))
    case = OUT / f'bishop_{dataset}_step_{step}'
    case.mkdir(parents=True, exist_ok=True)
    tagged = compact_sram([int(w, 16) for w in (original / 'commands.hex').read_text().split()
                           if int(w, 16) >> 16 != 65535])
    base = 0x300000
    (case / 'psram.hex').write_text((original / 'flash.hex').read_text() + f'@{base:x}\n' +
                                  ''.join(f'{w & 255:02x}\n{(w >> 8) & 255:02x}\n' for w in tagged))
    (case / 'phases.hex').write_text(''.join(f'{w >> 16:x}\n' for w in tagged))
    (case / 'expected.hex').write_text((original / 'expected.hex').read_text())
    meta = json.loads((original / 'metadata.json').read_text())
    meta.update(program_base=base, program_words=len(tagged))
    (case / 'stream.json').write_text(json.dumps(meta, indent=2) + '\n')
    return case


def run(case, binary):
    meta = json.loads((case / 'stream.json').read_text())
    args = [binary, f'+FIXTURE={case}/psram.hex', f'+EXPECTED={case}/expected.hex',
            f'+REPORT={case}/result.json', f'+PROFILE={case}/profile.json',
            f'+PHASES={case}/phases.hex', f'+PROGRAM={meta["program_base"]}',
            f'+WORDS={meta["program_words"]}', f'+INPUT_BYTES={meta["input_width"]}']
    with (case / 'simulation.log').open('w') as log:
        subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = json.loads((case / 'result.json').read_text())
    profile = json.loads((case / 'profile.json').read_text())
    assert result['mismatches'] == 0
    assert profile['program_cycles'] == result['core_cycles']
    row = dict(dataset=meta['dataset'], step=meta['step'], result=result,
               program_ms=result['core_cycles']/50000,
               total_ms=result['cycles']/50000,
               initialization_ms=sum(profile['phases'][0])/50000,
               output_ms=sum(profile['phases'][9])/50000)
    # Favorable sensitivity: erase warm-state setup cost, all UART costs and
    # output phase. This is not a separately implemented or measured protocol.
    row['optimistic_compute_ms'] = row['program_ms']-row['initialization_ms']-row['output_ms']
    print(json.dumps(row), flush=True)
    return row


def queue(service):
    finish = 0.0
    rows = []
    for i, duration in enumerate(service):
        arrival = i * 20.0
        start = max(arrival, finish)
        finish = start + duration
        rows.append(dict(arrival_ms=arrival, start_ms=start, finish_ms=finish,
                         latency_ms=finish-arrival, miss=finish-arrival > 100.0))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='/tmp/acc-deadline-buffered/Vtb_psram_network')
    parser.add_argument('--jobs', type=int, default=3)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    cases = []
    windows = []
    for dataset in range(4):
        trace = ROOT / f'reports/fp8_full/bishop_{dataset}'
        activity = np.genfromtxt(trace / 'activity.csv', delimiter=',', names=True, dtype=int)
        peak = int(np.argmax(activity['input'] + activity['previous']))
        # Keep the peak and its immediate two predecessors in the same trial.
        offsets = np.fromfile(trace / 'offsets.bin', dtype='<u8')
        assert not any(peak-2 < int(offset) <= peak for offset in offsets)
        steps = list(range(peak-2, peak+1))
        windows.append(dict(dataset=dataset, steps=steps))
        cases.extend(prepare(dataset, step) for step in steps)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        measured = list(pool.map(lambda case: run(case, args.binary), cases))
    for window in windows:
        rows = [r for r in measured if r['dataset'] == window['dataset']]
        window['frames'] = rows
        for field in ['total_ms', 'program_ms', 'optimistic_compute_ms']:
            window[field] = queue([r[field] for r in rows])
    source_files = list((ROOT / 'src/rtl').rglob('*')) + [Path(__file__), ROOT/'scripts/prepare_fp8_network.py', ROOT/'scripts/compact_sram.py', ROOT/'test/tb_psram_network.sv', ROOT/'test/psram_profile.svh']
    report = dict(clock_mhz=50, arrival_period_ms=20, deadline_ms=100, batch=1,
                  limits='Twelve independent warm-started full-network RTL frame measurements with buffered SRAM. FIFO projection, empty queue per three-frame window, no inter-frame gaps. Not full-trace mean or live streaming validation. 50MHz cycle conversion, not physical timing signoff. Optimistic variant subtracts setup and output phases and UART overhead.',
                  windows=windows,
                  source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in source_files if p.is_file()})
    (OUT / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    lines = ['# Current PSRAM stream: 20 ms arrivals, 100 ms deadlines', '',
             report['limits'], '',
             '| Dataset | Consecutive steps | Total service times (ms) | Total response times (ms) | Optimistic third response (ms) |',
             '|---|---|---|---|---|']
    for w in windows:
        lines.append(f'| bishop_{w["dataset"]} | {w["steps"][0]}–{w["steps"][-1]} | '+
                     ', '.join(f'{r["total_ms"]:.3f}' for r in w['frames'])+' | '+
                     ', '.join(f'{r["latency_ms"]:.3f}' for r in w['total_ms'])+
                     f' | {w["optimistic_compute_ms"][-1]["latency_ms"]:.3f} |')
    lines += ['', 'Each frame checks all 256 c states, all 256 y states, two FC values and PSRAM output. '+
              'Full EGRU/FC, instruction/weight fetch and result store are included. '+
              'The queue recurrence is finish[i] = max(20*i, finish[i-1]) + service[i]. '+
              'Total includes UART ingress and completion credit. Program-only removes those UART costs. '+
              'The optimistic sensitivity additionally removes initialization and output phases; it is not an implemented streaming mode.', '',
              'Selected windows establish counterexamples if any response exceeds 100 ms. '+
              'They do not estimate average workload, full-trace maximum queue size or the minimum clock that would pass all frames.', '',
              'Reproduce: `make -f test/Makefile.psram_network build BUILD=/tmp/acc-deadline-buffered`, '+
              'then `python3 scripts/evaluate_stream_deadline.py`. Raw measurements and queue projections: '+
              '`reports/stream_deadline/summary.json`. No RTL edits or synthesis.']
    (ROOT / 'docs/stream_deadline.md').write_text('\n'.join(lines)+'\n')


if __name__ == '__main__':
    main()
