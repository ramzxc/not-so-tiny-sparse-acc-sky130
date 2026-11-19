#!/usr/bin/env python3
"""Summarize current buffered-SRAM RTL profiles, with no synthesis or RTL edits."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/stream_deadline'
LABELS = ['DMA external transfer and handoff', 'DMA SRAM read/commit',
          'SRAM read-add-write', 'Other SRAM access', 'Other external access',
          'EXEC arithmetic/activation', 'MICRO control/handoff',
          'Exposed instruction fetch', 'Dispatch/drain']
PHASES = ['Initialization', 'Bias setup', 'Input u/r', 'Recurrent', 'Gates',
          'Input z', 'State update', 'FC', 'Fence', 'Output store']
STATES = ['IDLE','I_DATA','I_LO','I_HI','I_MEM','I_SYNC','COLUMN_CHECK','W_DATA',
          'W_LO','W_HI','W_MEM','W_SYNC','EXEC','EXEC_SYNC','STORE','A_LO','A_HI',
          'A_MEM','A_SYNC','COLUMN_END','B_NEXT','B_VALIDATE','D_SRC_LO','D_SRC_HI',
          'D_SOURCE','D_DST_LO','D_DST_HI','D_DEST','D_RUN','D_WAIT','D_NEXT','D_VALIDATE_INPUT']
summary = json.loads((OUT / 'summary.json').read_text())
rows = []
for window in summary['windows']:
    for frame in window['frames']:
        case = OUT / f'bishop_{frame["dataset"]}_step_{frame["step"]}'
        p = json.loads((case/'profile.json').read_text())
        r = json.loads((case/'result.json').read_text())
        assert r['mismatches'] == 0
        assert sum(p['partition']) == sum(map(sum, p['phases'])) == r['core_cycles']
        assert sum(p['micro_control_states']) == p['partition'][6]
        assert p['front_cycles']+p['program_cycles']+p['completion_cycles'] == r['cycles']
        for owner in (0,1):
            assert p['qpi_states'][owner][5] == 4*p['payload_bytes'][owner]
            assert sum(p['qpi_states'][owner]) == 27*p['requests'][owner]+4*p['payload_bytes'][owner]-(8 if owner==0 else 0)
        rows.append(dict(dataset=frame['dataset'],step=frame['step'],result=r,profile=p))
slow = max(rows,key=lambda r:r['result']['core_cycles'])
p = slow['profile']

def worst_latency(ids, fraction):
    worst = 0.0
    for window in summary['windows']:
        finish = 0.0
        for i,frame in enumerate(window['frames']):
            row = next(r for r in rows if r['dataset']==frame['dataset'] and r['step']==frame['step'])
            service = (row['result']['cycles']-fraction*sum(row['profile']['partition'][j] for j in ids))/50000
            finish = max(i*20,finish)+service
            worst = max(worst,finish-i*20)
    return worst

sensitivity = []
for name, ids in [('DMA',[0,1]),('MICRO control',[6]),('EXEC',[5]),('SRAM accumulation',[2]),('Instruction fetch',[7])]:
    sensitivity.append(dict(category=name,half_cost_max_latency_ms=worst_latency(ids,.5),zero_cost_max_latency_ms=worst_latency(ids,1)))
# Every weight tile in the three projection phases is 8/16/24 bytes and starts
# at SRAM byte 956 (4 mod 8). Aligning to 8 saves one QPI transaction per tile.
# Derive eligible tiles from the measured two-lane accumulations, six cycles each.
eligible_tiles = 0
for phase, groups in [(2,8),(3,12),(5,4)]:
    assert p['phases'][phase][2] % (6*groups) == 0
    eligible_tiles += p['phases'][phase][2] // (6*groups)
assert eligible_tiles + p['phases'][7][2]//6 == p['weight_dma_runs']
report = dict(partition_labels=LABELS,phase_labels=PHASES,micro_state_labels=STATES,
              cases=rows,representative=dict(dataset=slow['dataset'],step=slow['step']),
              sensitivity=sensitivity,aligned_weight_tile_transactions_saved=eligible_tiles,
              aligned_weight_tile_protocol_saving_ms=27*eligible_tiles/50000,
              limits='Selected high-activity windows, not workload averages. Exclusive categories add exactly; occupancy counters overlap. Counterfactual subtraction is not an implemented speedup. 50MHz cycles, 25MHz QPI SCK; not physical timing signoff.')
(OUT/'bottleneck.json').write_text(json.dumps(report,indent=2)+'\n')
lines = ['# Current buffered SRAM: complete-network bottlenecks','',report['limits'],'',
         'All 12 adjacent Bishop frames pass full state/FC/PSRAM comparisons. Only passive testbench counters were extended; functional RTL and synthesis were untouched.', '',
         f'Representative: bishop_{slow["dataset"]}, step {slow["step"]}. Program {p["program_cycles"]/50000:.5f} ms; UART front {p["front_cycles"]/50000:.5f} ms; completion credit {p["completion_cycles"]/50000:.5f} ms. Output store is already in program time.', '',
         '| Exclusive category | ms at 50 MHz | Program share |','|---|---:|---:|']
for label,count in zip(LABELS,p['partition']):
    lines.append(f'| {label} | {count/50000:.4f} | {100*count/p["program_cycles"]:.2f}% |')
lines += ['', 'DMA dominates with 31.1203 ms; MICRO control/handoff contributes 20.8183 ms. '+
          'DMA SRAM includes partial-row preservation reads as well as commits. Its other bucket includes external transfer and controller handoff, not exclusively PSRAM wire time.', '',
          '## External data traffic','',
          f'Data requests: {p["requests"][0]:,}; payload: {p["payload_bytes"][0]:,} bytes; average {p["payload_bytes"][0]/p["requests"][0]:.3f} bytes/request. '+
          'All but one request are reads; the last writes the two FC bytes. Row-bounded bursts are already implemented.', '',
          f'QPI data-controller active: {sum(p["qpi_states"][0])/50000:.5f} ms, of which '+
          f'{p["qpi_states"][0][5]/50000:.5f} ms transfers payload and '+
          f'{(sum(p["qpi_states"][0])-p["qpi_states"][0][5])/50000:.5f} ms is command/address/dummy/select/finish/recovery. '+
          'These are a decomposition of bus activity, not extra costs to add to the table.', '',
          '## MICRO exclusive control states','',
          '| State | ms excluding active DMA/memory/EXEC |','|---|---:|']
for index in sorted(range(32),key=lambda i:p['micro_control_states'][i],reverse=True):
    if p['micro_control_states'][index]:
        lines.append(f'| {STATES[index]} | {p["micro_control_states"][index]/50000:.4f} |')
lines += ['',f'For {p["sram_accumulates"]:,} two-lane accumulate operations, W_SYNC costs four exclusive cycles each; A_SYNC three each. '+
          'Together these account for 10.38786 ms beyond active memory/EXEC time. '+
          'W_DATA, EXEC, EXEC_SYNC and STORE add one exclusive cycle each (5.93592 ms together). '+
          'These are command/handshake and dependency costs, not proven removable idle cycles. Inspect DATA readiness and operand/result validity before any shortcut.', '',
          '## Network phases','', '| Phase | ms |','|---|---:|']
for label,counts in zip(PHASES,p['phases']):lines.append(f'| {label} | {sum(counts)/50000:.4f} |')
lines += ['', '## Deadline sensitivity: all four three-frame windows','',
          'Keep UART and every other category unchanged; subtract the specified fraction from measured service times and repeat FIFO queue calculation. '+
          'This is an accounting sensitivity, not a simulated modified design.', '',
          '| Category | Worst latency if cost halved (ms) | Worst latency if cost zero (ms) |','|---|---:|---:|']
for r in sensitivity:lines.append(f'| {r["category"]} | {r["half_cost_max_latency_ms"]:.3f} | {r["zero_cost_max_latency_ms"]:.3f} |')
lines += ['', 'The hardest window requires 219.43386 ms of current service across three arrivals at 0/20/40 ms. '+
          'To finish the third by 140 ms requires at least 36.20% total service reduction in that window '+
          '(1.567× uniform service rate). Excluding UART, initialization and output even optimistically, '+
          '204.85698 ms must fall to 140 ms: 31.66% reduction. These are necessary window-specific targets, not full-trace guarantees.', '',
          '## Next investigations, ordered for area','',
          f'1. Software SRAM layout: align the weight scratch base to eight bytes. It is currently 956, which splits 16-byte tiles into 4+8+4 and 24-byte tiles into 4+8+8+4. '+
          f'The representative frame has {eligible_tiles:,} eligible tiles: one fewer transaction each saves {27*eligible_tiles/50000:.3f} ms of protocol cycles, before changed SRAM/handshake costs. '+
          'A simple base edit overlaps accumulators. The current generator reserves eight bytes each for temp_a/temp_b although each pair is consumed within one state-update iteration; verify pair reuse, then repack scratch/accumulators. This candidate changes software layout, not SRAM capacity or arithmetic order. Not yet implemented.',
          '2. DATA/MICRO handoff: investigate the W_SYNC/A_SYNC residual cycles, and compact input-load/DMA setup where invariants permit. Preserve batch support and all memory/execution fences until dependencies are explicitly satisfied. No new cache or MAC needed merely to investigate.',
          '3. SRAM accumulation path: six cycles per two-byte read-add-write. Reducing repeated row transfers or retaining accumulators could help, but buffers/registers and rounding order become explicit tradeoffs. Measure after the software/handshake candidates.',
          '4. Larger bursts, wider compute or more buffering are later tradeoffs. Halving DMA alone still gives a 139.174 ms worst selected response. Eliminating instruction-fetch cost alone leaves 168.439 ms; instruction caching cannot solve this by itself.', '',
          'Reproduce: run `scripts/evaluate_stream_deadline.py` with the profiled current binary, then '+
          '`python3 scripts/summarize_current_bottleneck.py`. Raw evidence: `reports/stream_deadline/bottleneck.json`.']
(ROOT/'docs/current_bottleneck.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines[:18]))
print(json.dumps(sensitivity,indent=2))
