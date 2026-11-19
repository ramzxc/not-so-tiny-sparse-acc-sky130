#!/usr/bin/env python3
"""Summarize measured selected-frame RTL runs, never a dataset-wide timing average."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/fp8_full'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
rows=[]
for name in json.loads((OUT/'cases.json').read_text()):
 case=Path(name);meta=json.loads((case/'metadata.json').read_text())
 r=json.loads((case/'result.json').read_text())
 assert r['mismatches']==0 and r['flash_programs']==0
 assert sum(r['phase_cycles'])==r['cycles']
 row=dict(dataset=meta['dataset'],step=meta['step'],**r)
 row.update(ms_50mhz=r['cycles']/50000,wire_lower_bound_ms=sum(r['phase_words'])*20*87/50000,
            phase_ms_50mhz=dict(zip(meta['phases'],[v/50000 for v in r['phase_cycles']])),
            fixture_sha256={p.name:digest(p) for p in [case/'flash.hex',case/'commands.hex',case/'expected.hex']})
 if (case/'uart8.json').exists():row['uart8']=json.loads((case/'uart8.json').read_text())
 rows.append(row)
files=list((ROOT/'src/rtl').rglob('*'))+[ROOT/'scripts/prepare_fp8_network.py',ROOT/'scripts/fp8_egru_trace.cpp',ROOT/'test/tb_fp8_network.sv']
summary=dict(clock_hz=50000000,uart_clks_per_bit=87,input_period_ms_assumed=20,latency_budget_ms=100,
 scope='Complete input DMA, EGRU and FC to SRAM, batch 1, eight-neuron tiles; selected warm-started frames, not continuous full-dataset RTL.',
 excluded='PC/sensor-to-Flash input transport, FC output transport, board setup, one-time initial state loading. No physical timing or accuracy signoff.',
 cases=rows,sources_sha256={str(p.relative_to(ROOT)):digest(p) for p in files if p.is_file()})
(OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
lines=['# FP8 / 1 KiB full EGRU + FC performance','',
'For separate front/core/back measurements, see [the consumer report](performance_fp8_consumer.md).','',
'Current not-so-tiny RTL, batch 1, 50 MHz cycle conversion. UART divider 87 (574,713 baud). Input period 20 ms and per-input latency budget 100 ms are assumptions, not dataset timestamps.','',
'## Measured selected frames','',
'| Dataset | Step | Whole step (ms) | MICRO busy (ms) | UART wire-only lower bound (ms) |',
'|---|---:|---:|---:|---:|']
for r in rows:lines.append(f"| bishop_{r['dataset']} | {r['step']} | {r['ms_50mhz']:.3f} | {r['micro_cycles']/50000:.3f} | {r['wire_lower_bound_ms']:.3f} |")
lo=min(r['ms_50mhz'] for r in rows);hi=max(r['ms_50mhz'] for r in rows)
lines+=['',f'All {len(rows)} cases passed bit-exact comparison of 256 cell states, 256 emitted states, and both FC outputs. Selected service times are {lo:.3f}–{hi:.3f} ms: {lo/20:.1f}–{hi/20:.1f} times the 20 ms arrival period. This schedule cannot sustain the stream or meet a 100 ms deadline, even before external I/O. A PC queue cannot absorb a sustained service-rate deficit.',
'', '## Coverage and schedule','',
'For each of four Bishop datasets, test step 0, step 100, and the step maximizing active input plus active previous-output count in the FP8 trace. The latter is a high-activity sample, not a proven worst latency. Reference traces cover all 103,133 dataset steps with trial resets. RTL runs only the 12 selected frames, initialized from the immediately preceding reference states. No full-dataset RTL average or original-model task accuracy is claimed.',
'', 'Each step includes input Flash-to-SRAM DMA, bias loads, input U/R projections, recurrent U/R/Z projections, sigmoid and reset multiplication, input Z projection, tanh, cell/event/reset updates, and the two-output FC head. All commands enter through physical UART pins with READY credits; weights use pin-level QSPI NOR and the actual 1 KiB SRAM simulation model. SRAM is not preloaded through a backdoor. State/FC readback for validation uses observation only.',
'', 'SRAM bytes: c 0–255; old y 256–511; new y 512–767; input 768–955; DMA tile/threshold 956–979; U/R/Z gates 980–1003; temporaries 1004–1019; FC 1020–1021; ones 1022–1023. Eight hidden outputs are completed per tile. Preserve old y until all recurrent consumers finish; the old/new buffer roles can swap for a subsequent step. No Flash programs or external state spills occur. This is one valid schedule, not a proof of an optimal schedule.',
'', 'The MICRO sequencer runs matrix columns autonomously, including burst DMA. Pointwise gates and state updates still require host LOAD/EXEC/STORE instruction sequences. Redundant unchanged address/config fields are omitted, and there are no per-tile host fences. Explicit SYNC protects operand/result dependencies. The timing includes these instruction costs.',
'', '## Bottleneck and sensitivity','']
r=rows[0]
for k,v in r['phase_ms_50mhz'].items():
 if v:lines.append(f'- {k}: {v:.3f} ms.')
lines+=['','Phase times partition wall time by the host instruction being supplied, including any wait for the preceding operation. They are not isolated engine costs. MICRO and DMA busy counters overlap; do not add them. The wire-only bound counts 20 UART bits per 16-bit word and excludes READY, compute and stalls.']
lines.append('')
for r in rows:
 if 'uart8' in r:lines.append(f"- Sensitivity only, bishop_{r['dataset']} step {r['step']}, divider 8 (6.25 Mbaud): {r['uart8']['cycles']/50000:.3f} ms, bit-exact outputs. The production RTL default was not changed.")
lines+=['','First reduce per-element host instruction traffic, e.g. a generic MICRO vector-ALU sequence/loop or locally stored instruction stream, then remeasure. Faster UART alone is insufficient in these tests. High-activity matrix work itself also exceeds the 20 ms interval; investigate tile sizing, state/workspace reuse and weight transfer reuse after command overhead is removed. These are proposed design changes, not measured speedups or area-free promises.',
'', '## Limits','',
'Inputs are already present in Flash when measurement begins. Count their DMA into SRAM, but exclude PC/sensor input delivery, board initialization, warm-start state loading and FC return transport. Current UART returns READY, not the numerical FC result. This is a lower bound on end-to-end system latency. 50 MHz is a cycle conversion, not SRAM/logic/board timing closure.',
'', 'The independent exact-rational E4M3FN oracle supplies arithmetic tables. The model follows egru/sim gate order, using chip hard sigmoid/tanh and separately quantized bias plus recurrent_bias added in FP8. FC adds outputs in ascending hidden index. Numerical behavior differs from the original FP16/true-activation model; task accuracy needs separate evaluation.',
'', '## Reproduce','', 'From the repository root, after preparing the Bishop FP8 files:', '', '```sh','python3 scripts/prepare_bishop_fp8.py','make -f test/Makefile.network','python3 scripts/summarize_fp8_network.py','```','', 'For the divider-8 sensitivity, rebuild the same bench with `-GUART_CLKS_PER_BIT=8` into a separate build directory, then use `scripts/run_fp8_network.py --limit 3 --binary <binary> --report-name uart8`. Artifacts are in `reports/fp8_full/`: source/fixture hashes and all measured counters in `summary.json`; per-case command/Flash/expected fixtures and simulation logs; full software reference traces and the arithmetic contract.']
(ROOT/'docs/performance_fp8_1k.md').write_text('\n'.join(lines)+'\n')
print(f'{len(rows)} complete cases passed; {lo:.3f}–{hi:.3f} ms at 50 MHz')
