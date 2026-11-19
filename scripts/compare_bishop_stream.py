#!/usr/bin/env python3
"""Compare measured host scheduling changes with unchanged Bishop/core models."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from evaluate_bishop_auto_dma import schedule

ROOT = Path(__file__).resolve().parents[1]


def add_deadline_metrics(report, data, baseline):
    """Uniform service-time sensitivity on each selected batch-one trace."""
    for row in report['datasets']:
        if row['batch'] != 1:
            continue
        with np.load(data/row['dataset']/'fp16/test.npz') as source:
            x = source['inputs'] != 0
            offsets = source['trial_offsets']
        core, host, tiles = schedule(x[:,None,:], row['selected_chunk'], row['selected_groups'],
                                    baseline['coefficients'], baseline['host_floor_cycles'],
                                    baseline['host_overhead_cycles'])
        saved = (report['baseline_observation_pad_cycles']*tiles +
                 (tiles-1)*(report['saved_cycles_per_intermediate_fence'] +
                            report['saved_cycles_per_known_high_address']) +
                 report['saved_cycles_final_fence'])
        service = (host-saved)/50000
        arrivals = np.arange(len(service))*20

        def latency(durations):
            total = np.cumsum(durations)
            finish = total + np.maximum.accumulate(arrivals-(total-durations))
            return finish-arrivals

        lo, hi = 0.0, 1.0
        for _ in range(40):
            mid = (lo+hi)/2
            if latency(service*mid).max() <= 100:
                lo = mid
            else:
                hi = mid
        core_latency = latency(core/50000)
        row.update(input_only_uniform_service_reduction_for_trace_deadlines_pct=100*(1-lo),
                   core_only_deadline_misses=int((core_latency>100).sum()),
                   core_only_worst_latency_ms=float(core_latency.max()))
        # Favorable boundary condition: each trial starts with an empty queue.
        # This does not infer real gaps from a dataset with no timestamps.
        trial_latencies = {}
        for name, durations in [('host', service), ('core', core/50000)]:
            latencies = []
            for start, stop in zip(offsets[:-1], offsets[1:]):
                part = durations[start:stop]
                times = np.arange(len(part))*20
                total = np.cumsum(part)
                finish = total + np.maximum.accumulate(times-(total-part))
                latencies.extend(finish-times)
            values = np.array(latencies)
            trial_latencies[name] = dict(misses=int((values>100).sum()),
                                         worst_latency_ms=float(values.max()))
        row['empty_queue_at_each_trial'] = trial_latencies


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--measurements', type=Path, default=Path('/tmp/acc-stream-compact/measurements.json'))
    ap.add_argument('--mixed', type=Path, default=Path('/tmp/acc-stream-mixed/measurements.json'))
    ap.add_argument('--baseline', type=Path, default=ROOT/'reports/bishop_auto_dma/estimate.json')
    ap.add_argument('--data', type=Path, default=Path('/docker/projects/egru/sim/data/sdc_raw'))
    ap.add_argument('--output', type=Path, default=ROOT/'reports/stream/estimate.json')
    args = ap.parse_args()
    old = json.loads(args.baseline.read_text())
    uniform = json.loads(args.measurements.read_text())
    mixed = json.loads(args.mixed.read_text())
    assert uniform['uart_divider'] == mixed['uart_divider'] == 87
    rows = uniform['rows'] + mixed['rows']
    lookup = {r['name']: r for r in rows}
    one, two = lookup['b1_small_n1'], lookup['b1_small_n2']
    fence_saving = one['baseline_cycles'] - one['stream_cycles']
    stream_saving = two['baseline_cycles'] - two['stream_cycles'] - fence_saving
    address_saving = two['stream_cycles'] - two['compact_cycles']
    for row in rows:
        n = row['repeats']
        assert row['baseline_cycles'] - row['stream_cycles'] == (n-1)*stream_saving + fence_saving
        assert row['stream_cycles'] - row['compact_cycles'] == (n-1)*address_saving
    # Existing RTL calibration starts eight clocks before this experiment's
    # post-SYNC observation point. Account for that baseline offset explicitly.
    baseline_pad = old['host_floor_cycles'] - one['baseline_cycles']
    assert baseline_pad == 8
    for row in uniform['rows']:
        n = row['repeats']
        predicted = n*(max(old['host_floor_cycles'], row['micro_cycles']//n +
                          old['host_overhead_cycles']) - baseline_pad)
        assert predicted == row['baseline_cycles']
    current_hashes = {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest()
                      for p in old['source_sha256']}
    assert current_hashes == old['source_sha256'], 'RTL differs from baseline'
    report = {'scope': 'Input projection schedule estimate; output equivalence measured on finite RTL fixtures.',
              'clock_mhz': 50, 'uart_divider': 87, 'rtl_unchanged': True,
              'measured_equivalence_cases': len(rows),
              'saved_cycles_per_intermediate_fence': stream_saving,
              'saved_cycles_per_known_high_address': address_saving,
              'saved_cycles_final_fence': fence_saving,
              'baseline_observation_pad_cycles': baseline_pad,
              'omitted': old['omitted'], 'source_sha256': current_hashes,
              'assumptions': old['assumptions'] + [
                  'stream across tile boundaries; final fence once per batch',
                  'compact address mode requires known staging high=0 between SRAM runs',
                  'movement/reconfiguration costs are still zero, as in the prior estimate',
                  'historical fixed16 hidden activity is only a sensitivity proxy, not current FP16 activity'],
              'datasets': []}
    for ds in range(4):
        directory = args.data/f'bishop_{ds}'
        x = np.load(directory/'fp16/test.npz')['inputs'] != 0
        historical = json.loads((directory/'fixed16/summary.json').read_text())
        hidden = historical['test_at_best_validation_epoch']['event_count'] / len(x)
        for batch in (1,2,4):
            z = x[:len(x)//batch*batch].reshape(-1,batch,x.shape[1])
            previous = next(r for r in old['datasets'] if r['dataset'] == f'bishop_{ds}' and r['batch'] == batch)
            best = None
            same = None
            for chunk in sorted(set(list(range(2,x.shape[1]+1,2)) + [x.shape[1]])):
                groups = (512-4*((chunk+1)//2)*batch)//(4*(batch+1))
                if groups < 1:
                    continue
                core, host, n = schedule(z, chunk, groups, old['coefficients'],
                                         old['host_floor_cycles'], old['host_overhead_cycles'])
                baseline = host - baseline_pad*n
                stream = baseline - (n-1)*stream_saving - fence_saving
                compact = stream - (n-1)*address_saving
                assert np.all(compact >= core)
                if chunk == previous['input_chunk']:
                    same = dict(baseline=float(baseline.mean()/batch/50000),
                                stream=float(stream.mean()/batch/50000),
                                compact=float(compact.mean()/batch/50000))
                if best is None or compact.mean() < best[0]:
                    best = (compact.mean(), chunk, groups, core, compact, n)
            _, chunk, groups, core, compact, n = best
            service = compact/50000
            finish = 0.0
            misses = 0
            worst = 0.0
            for j, duration in enumerate(service):
                finish = max(finish, (j*batch+batch-1)*20) + duration
                latency = finish - (j*batch+np.arange(batch))*20
                misses += int((latency > 100).sum())
                worst = max(worst, float(latency.max()))
            mean = float(service.mean()/batch)
            row = dict(dataset=f'bishop_{ds}', batch=batch, same_schedule_ms_per_input=same,
                       selected_chunk=chunk, selected_groups=groups, tiles_per_batch=n,
                       optimized_mean_ms_per_input=mean, core_mean_ms_per_input=float(core.mean()/batch/50000),
                       input_only_batch_service_p99_ms=float(np.percentile(service,99)),
                       input_only_batch_service_max_ms=float(service.max()),
                       input_only_deadline_misses=misses, input_only_worst_latency_ms=worst,
                       input_only_mean_remaining_ms=20-mean,
                       historical_hidden_active_mean=hidden)
            if batch == 1:
                # Optimistic recurrent transfer+compute slope only: no headers,
                # UART, tiling, gates, head or state movement. Not a network run.
                recurrent_proxy = hidden*768*31.5/50000
                total_proxy = mean+recurrent_proxy
                row.update(historical_recurrent_slope_only_ms=recurrent_proxy,
                           optimistic_proxy_total_ms=total_proxy,
                           proxy_service_reduction_for_20ms_pct=100*max(0,1-20/total_proxy),
                           proxy_service_reduction_for_16ms_pct=100*max(0,1-16/total_proxy),
                           hidden_active_budget_without_other_work=max(0,20-mean)/(768*31.5/50000))
            report['datasets'].append(row)
            print(row['dataset'], batch, same, 'best',round(mean,4),f'C{chunk} G{groups}',
                  'input-only deadline misses',misses, flush=True)
    add_deadline_metrics(report, args.data, old)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__':
    main()
