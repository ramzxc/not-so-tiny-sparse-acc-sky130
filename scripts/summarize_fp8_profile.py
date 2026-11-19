#!/usr/bin/env python3
"""Exclusive cycle attribution; these selected-frame profiles are not averages."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/fp8_full'
NAMES=['dma_read','dma_sram_commit','dma_other','micro_weight_load','micro_exec_sequence','micro_accumulate_store','micro_input_scan','micro_dma_setup','micro_validation','non_micro']
rows=[]
for name in json.loads((OUT/'consumer_cases.json').read_text()):
    case=Path(name);r=json.loads((case/'profile.json').read_text());old=json.loads((case/'result.json').read_text())
    assert r['mismatches']==0 and r['compute_cycles']==old['compute_cycles']
    assert sum(r['core_profile'])==sum(r['qspi_profile'])==sum(r['sram_profile'])==r['compute_cycles']
    q=r['qspi_profile'];header=sum(q[i] for i in (1,2,3,4,6,7,8));payload=q[5];byte_count=payload//4
    assert header==118*r['flash_reads'] and r['dma_cycles']==header+10*byte_count
    rows.append(dict(case=case.name,compute_cycles=r['compute_cycles'],exclusive_cycles=dict(zip(NAMES,r['core_profile'])),
                     dma_cycles=r['dma_cycles'],exec_active_cycles=r['exec_active_cycles'],flash_read_bursts=r['flash_reads'],
                     flash_bytes=byte_count,qspi_header_cycles=header,qspi_payload_cycles=payload,
                     dma_other_read_handshake_cycles=r['core_profile'][0]-header-payload))
(OUT/'core_profile_summary.json').write_text(json.dumps(dict(scope='Core only, ideal command availability; no UART waits or output Flash programming. Selected frames, not a dataset average.',cases=rows),indent=2)+'\n')
r=next(r for r in rows if r['case']=='consumer_bishop_0_step_100');total=r['compute_cycles']
lines=['# FP8 core bottleneck profile','',
'Exclusive cycle counters added to the consumer testbench only. All 12 selected Bishop RTL frames still match reference states/FC/Flash output, with identical total cycles to the earlier runs. No functional RTL optimization is included.','',
'## Representative frame: Bishop 0, step 100','',
'50 MHz, ideal command availability, input DMA through full EGRU+FC: **40.707 ms**. This is an illustrative frame, not the dataset mean.','',
'| Exclusive core category | ms | Percent |','|---|---:|---:|']
for name,c in r['exclusive_cycles'].items():
    if c:lines.append(f'| {name} | {c/50000:.4f} | {100*c/total:.2f}% |')
lines+=['',f"Across the 12 selected frames, DMA occupies {min(v['dma_cycles']/v['compute_cycles'] for v in rows)*100:.1f}–{max(v['dma_cycles']/v['compute_cycles'] for v in rows)*100:.1f}% of core time. EXEC busy occupies {min(v['exec_active_cycles']/v['compute_cycles'] for v in rows)*100:.1f}–{max(v['exec_active_cycles']/v['compute_cycles'] for v in rows)*100:.1f}%.",
'', 'DMA busy is attributed first; remaining MICRO cycles are grouped by FSM state. Weight-load and accumulate-store buckets include their command/address and synchronization overhead, not just SRAM macro access. EXEC-sequence includes instruction dispatch and waiting; the independent EXEC busy counter measures actual unit occupancy. Orthogonal QSPI/SRAM/EXEC counters overlap these categories and must not be added to them.',
'', '## Why DMA is expensive despite burst support','',
f"This frame issues {r['flash_read_bursts']:,} read bursts for {r['flash_bytes']:,} bytes: {r['flash_bytes']/r['flash_read_bursts']:.2f} bytes/burst on average. Weight tiles are generally 8/16/24 bytes. A tile retains CS across its bytes, but the next column/tile starts another transaction.",
'', 'Measured DMA decomposition (the same identity holds in all 12 profiles):','',
'`DMA cycles = 118 × number_of_bursts + 10 × number_of_bytes`','',
f"- Transaction/status/header overhead: {r['qspi_header_cycles']/50000:.4f} ms ({100*r['qspi_header_cycles']/total:.2f}% of core).",
f"- Actual quad payload shifts: {r['qspi_payload_cycles']/50000:.4f} ms ({100*r['qspi_payload_cycles']/total:.2f}% of core).",
f"- Byte/vector delivery and read-side handshake: {r['dma_other_read_handshake_cycles']/50000:.4f} ms.",
f"- SRAM commit side of DMA: {r['exclusive_cycles']['dma_sram_commit']/50000:.4f} ms.",
'', 'Thus the physical Flash payload rate alone is not the main limit. Status/address overhead and per-byte/per-two-byte handoffs consume substantial time. These identities characterize this controller/profile; they are not universal Flash timing constants.',
'', '## Improvement order, retaining FP8 operation order','',
'1. **Small sequencer simplifications first.** In validated auto-DMA SRAM paths, avoid re-emitting an already-zero ADDR high word and unchanged DATA mode per two-byte vector. Preserve Flash-input and ordinary MICRO cases. W_HI/A_HI account for two command cycles per vector; eliminating both in this representative path has a simple upper bound of 53,084 cycles = 1.062 ms (2.61%), not the required overall speedup. This is a candidate, not a verified patch.',
'2. **Reduce DMA handoffs / exploit 64-bit SRAM rows.** The macro row is eight bytes, but the current path commits two bytes at a time, reading the row first to preserve other lanes. Assemble aligned complete rows and commit once; retain a correct merge path for unaligned heads/tails. Reduce byte request/response bubbles. Investigate reusing the existing row register before allocating a new buffer. Savings need RTL validation; control and storage cost are not assumed zero.',
'3. **Reduce repeated SRAM weight loads and accumulator read-modify-writes.** Each two-lane product is stored and accumulated back into SRAM, then the next column repeats the sequence. A row cache or retained tile accumulator could reduce this traffic, but needs flush/coherence rules and extra state. Preserve rounded FP8 multiply-then-add and column order; fused MAC or reordered reduction would change results.',
'4. **Lengthen useful Flash bursts where storage/schedule permits.** Larger output tiles reduce header count; the current 1 KiB layout is full, so this requires workspace reuse or more storage. Sparse columns and U/R-versus-Z dependencies prevent simply joining arbitrary adjacent requests. Larger SRAM is a real area tradeoff.',
'', 'Adding arithmetic lanes is not the first target: EXEC is busy for only about 8.3% of this representative core execution. Even making just that occupancy disappear would save at most about 8.3% of the measured schedule; SRAM accumulation arithmetic and transfers would remain. Pipelining/overlap would be a separate architectural change with separate costs.',
'', '## Reproduce','', '```sh','make -f test/Makefile.consumer build','python3 scripts/run_fp8_network.py --cases consumer_cases.json --jobs 3 --binary /tmp/acc-fp8-consumer/Vtb_fp8_consumer --report-name profile','python3 scripts/summarize_fp8_profile.py','```','',
'Per-cycle attribution is in `test/tb_fp8_consumer.sv`; raw JSON counters and logs are under each `reports/fp8_full/consumer_*` case. See [consumer boundary and timing assumptions](performance_fp8_consumer.md).']
(ROOT/'docs/performance_fp8_core_profile.md').write_text('\n'.join(lines)+'\n')
print('12 profiles validated; exclusive buckets sum exactly to core time')
