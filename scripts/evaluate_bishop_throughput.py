#!/usr/bin/env python3
"""Combine measured RTL component cycles with explicitly historical workload stats.

This is a throughput estimate, NOT an end-to-end EGRU or deadline simulation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--measurements', type=Path, default=Path('/tmp/acc-throughput-hw/measurements.json'))
    ap.add_argument('--data', type=Path, default=Path('/docker/projects/egru/sim/data/sdc_raw'))
    ap.add_argument('--clock-mhz', type=float, default=50)
    ap.add_argument('--output', type=Path, default=ROOT/'reports/throughput/bishop_estimate.json')
    args = ap.parse_args()
    assert args.clock_mhz > 0
    m = json.loads(args.measurements.read_text())
    dma = {r['bytes']:r['busy_cycles'] for r in m['dma']}
    micro = {r['macs']:r['busy_cycles'] for r in m['micro'] if r['columns']==1 and not r['zero']}
    dma_per_byte = (dma[512]-dma[256])/256
    core_per_mac = (micro[64]-micro[32])/32
    total_per_mac = 2*dma_per_byte+core_per_mac
    # Regression against independently measured sizes, not a peak-rate assumption.
    assert all(c == dma_per_byte*n + dma[4]-4*dma_per_byte for n,c in dma.items())
    assert all(c == core_per_mac*n + micro[2]-2*core_per_mac for n,c in micro.items())
    report = {'scope':'Measured component cycles + historical sparse workload estimate; not full EGRU RTL replay.',
              'assumptions':['batch=1, 20 ms arrivals, 100 ms per-input deadline',
                             'each used FP16 weight is DMA-loaded once; no weight cache hits',
                             'DMA and MICRO do not overlap',
                             'hidden event means are from fixed16 export, not the chip FP16/hard activation',
                             'event means approximate previous-state nonzeros; trial boundaries not reconstructed',
                             'optimistic estimates omit DMA headers, tiling setup, UART, activation and state spills'],
              'clock_mhz':args.clock_mhz, 'measurements':m,
              'dma_cycles_per_byte_asymptotic':dma_per_byte,
              'micro_cycles_per_mac_asymptotic':core_per_mac,
              'combined_cycles_per_mac_asymptotic':total_per_mac,
              'source_sha256':{}, 'datasets':[]}
    for name in ['core/dma_ctrl.v','core/micro_ctrl.v','core/exec_unit.sv','mem_itf.sv','qspi_ctrl.v','project.v']:
        p=ROOT/'src/rtl'/name
        report['source_sha256'][str(p.relative_to(ROOT))]=hashlib.sha256(p.read_bytes()).hexdigest()
    for i in range(4):
        p=args.data/f'bishop_{i}'
        with np.load(p/'fp16/test.npz') as z: x=z['inputs']
        summary=json.loads((p/'fixed16/summary.json').read_text())
        ax=np.count_nonzero(x,axis=1)
        events=summary['test_at_best_validation_epoch']
        assert events['event_total']==len(x)*256
        ay=events['event_count']/len(x)
        mac=768*(float(ax.mean())+ay)+2*ay
        cycles=mac*total_per_mac
        report['datasets'].append({'dataset':f'bishop_{i}','steps':len(x),'inputs':x.shape[1],
            'active_input_mean':float(ax.mean()),'active_input_p99':float(np.percentile(ax,99)),
            'active_input_max':int(ax.max()),'historical_hidden_event_mean':ay,
            'estimated_macs_per_step':mac,
            'optimistic_mean_service_ms':cycles/(args.clock_mhz*1000),
            'optimistic_min_mhz_for_mean_20ms':cycles/20000,
            'optimistic_min_mhz_for_mean_16ms':cycles/16000,
            'measured_host_tile_schedule_input_projection_only_ms':
                float(ax.mean())*12*m['host_tile']['cycles']/(args.clock_mhz*1000)})
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(args.output)
    for r in report['datasets']:
        print(r['dataset'],f"optimistic internal {r['optimistic_mean_service_ms']:.2f} ms/step",
              f"host tile input-only {r['measured_host_tile_schedule_input_projection_only_ms']:.1f} ms/step")

if __name__ == '__main__':main()
