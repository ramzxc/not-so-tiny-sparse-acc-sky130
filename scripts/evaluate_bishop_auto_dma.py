#!/usr/bin/env python3
"""Calibrated input-projection timing estimate, not a numerical EGRU replay."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def calibrate(rows):
    coefficients = {}
    for name, batches in [('single', [1]), ('batch', [2, 4])]:
        selected = [r for r in rows if r['batch'] in batches]
        # C16 random cases supply the fourth independent geometry. C19 and
        # actual Bishop masks remain held out (nine cases across all batches).
        train = [r for r in selected if not r['validation'] or r['name'].endswith('c16')]
        matrix = np.array([r['features'] for r in train])
        coef, _, rank, _ = np.linalg.lstsq(matrix, [r['micro_cycles'] for r in train], rcond=None)
        assert rank == matrix.shape[1]
        coef = np.rint(coef).astype(int)
        assert all(int(np.dot(r['features'], coef)) == r['micro_cycles'] for r in selected)
        coefficients[name] = coef.tolist()
    floor = min(r['host_cycles'] for r in rows)
    overhead = min(r['host_cycles'] - r['micro_cycles'] for r in rows)
    assert all(r['host_cycles'] == max(floor, r['micro_cycles'] + overhead) for r in rows)
    return coefficients, floor, overhead


def schedule(mask, chunk, groups, coefficients, floor, overhead):
    n, batch, width = mask.shape
    core = np.zeros(n, dtype=np.int64)
    host = core.copy()
    transactions = 0
    full, tail = divmod(384, groups)  # 768 gate outputs, two FP16s per group.
    for start in range(0, width, chunk):
        m = mask[:, :, start:start + chunk]
        columns = m.shape[2]
        pairs = (columns + 1) // 2
        union = m.any(axis=1)
        used = union.sum(axis=1)
        active = m.sum(axis=(1, 2))
        scan = np.where(union, m.argmax(axis=1) + 1, batch).sum(axis=1)
        for g, count in [(groups, full), (tail, int(tail > 0))]:
            if not count:
                continue
            if batch == 1:
                features = [1, g, pairs, columns, used, used * g]
                coef = coefficients['single']
            else:
                features = [1, g, pairs, columns, scan, used, used*g, used*g*batch, active*g]
                coef = coefficients['batch']
            cycles = sum(a * b for a, b in zip(features, coef))
            core += count * cycles
            host += count * np.maximum(floor, cycles + overhead)
            transactions += count
    return core, host, transactions


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--measurements', type=Path, default=Path('/tmp/acc-bishop-eval/measurements.json'))
    ap.add_argument('--data', type=Path, default=Path('/docker/projects/egru/sim/data/sdc_raw'))
    ap.add_argument('--output', type=Path, default=ROOT/'reports/bishop_auto_dma/estimate.json')
    args = ap.parse_args()
    measurements = json.loads(args.measurements.read_text())
    assert measurements['uart_divider'] == 87
    co, floor, overhead = calibrate(measurements['rows'])
    report = {'scope': 'Input projection only; calibrated timing model, not full-network RTL execution.',
              'clock_mhz': 50, 'arrival_ms': 20, 'deadline_ms': 100,
              'calibration_cases': 39, 'held_out_cases': 9, 'cycle_prediction_error': 0,
              'coefficients': co, 'host_floor_cycles': floor, 'host_overhead_cycles': overhead,
              'omitted': ['input transfer/packing', 'output initialization, readback and partial-sum spills',
                          'configuration changes between tiles', 'recurrent projection',
                          'gate activations, state updates and head'],
              'assumptions': ['20 ms is assumed: these NPZ files contain no timestamps',
                              'retained-config 11-word host RUN/SYNC for every tile, UART divider 87',
                              'one fixed input chunk and maximum fitting output group count per schedule',
                              'continuous concatenation of test rows; real inter-trial gaps unknown',
                              'last incomplete batch dropped; recurrent timesteps are not batched'],
              'source_sha256': {}, 'datasets': []}
    for p in sorted((ROOT/'src/rtl').rglob('*')):
        if p.suffix in ('.v', '.sv', '.vh'):
            report['source_sha256'][str(p.relative_to(ROOT))] = hashlib.sha256(p.read_bytes()).hexdigest()
    for ds in range(4):
        path = args.data/f'bishop_{ds}/fp16/test.npz'
        x = np.load(path)['inputs'] != 0
        for batch in (1, 2, 4):
            z = x[:len(x)//batch*batch].reshape(-1, batch, x.shape[1])
            best = None
            for chunk in sorted(set(list(range(2, x.shape[1]+1, 2)) + [x.shape[1]])):
                groups = (512 - 4*((chunk+1)//2)*batch) // (4*(batch+1))
                if groups < 1:
                    continue
                core, host, tiles = schedule(z, chunk, groups, co, floor, overhead)
                if best is None or host.mean() < best[0]:
                    best = (host.mean(), chunk, groups, core, host, tiles)
            _, chunk, groups, core, host, tiles = best
            service = host / 50000
            finish = 0.0
            misses = 0
            worst_latency = 0.0
            for j, duration in enumerate(service):
                ready = (j*batch + batch - 1)*20
                finish = max(finish, ready) + duration
                latency = finish - (j*batch + np.arange(batch))*20
                misses += int((latency > 100).sum())
                worst_latency = max(worst_latency, float(latency.max()))
            row = {'dataset': f'bishop_{ds}', 'batch': batch, 'rows': len(z)*batch,
                   'input_chunk': chunk, 'groups': groups, 'tiles_per_batch': tiles,
                   'active_mean': float(x.sum(axis=1).mean()),
                   'union_mean': float(z.any(axis=1).sum(axis=1).mean()),
                   'core_mean_ms_per_input': float(core.mean()/batch/50000),
                   'host_mean_ms_per_input': float(service.mean()/batch),
                   'batch_service_p99_ms': float(np.percentile(service, 99)),
                   'batch_service_max_ms': float(service.max()),
                   'input_only_deadline_misses': misses,
                   'input_only_worst_latency_ms': worst_latency,
                   'input_only_mean_required_mhz': float(host.mean()/batch/20000)}
            report['datasets'].append(row)
            print(row['dataset'], batch, f"chunk={chunk} groups={groups} tiles={tiles}",
                  f"core={row['core_mean_ms_per_input']:.3f} host={row['host_mean_ms_per_input']:.3f} ms/input",
                  f"deadline misses={misses}/{row['rows']}", flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
