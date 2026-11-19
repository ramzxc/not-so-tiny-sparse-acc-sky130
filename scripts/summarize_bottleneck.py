#!/usr/bin/env python3
"""Summarize passive RTL counters; never changes RTL or runs synthesis."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/bottleneck';OUT.mkdir(exist_ok=True)
labels=['DMA external-read wait','DMA SRAM-write wait','SRAM accumulation','Other SRAM access','Other external access','EXEC active','MICRO control / handoff','Exposed instruction fetch','Dispatch / drain']
phases=['initialization','bias setup','input u/r','recurrent','gates','input z','state update','FC','fence','output store']
baseline={r['case']:r['result'] for r in json.loads((ROOT/'reports/micro_reduction/before.json').read_text())}
rows=[]
for name in json.loads((ROOT/'reports/psram_stream/cases.json').read_text()):
 case=Path(name);m=json.loads((case/'stream.json').read_text());r=json.loads((case/'result.json').read_text());p=json.loads((case/'profile.json').read_text())
 assert r==baseline[case.name],case
 assert sum(p['partition'])==p['program_cycles']==r['core_cycles']
 assert sum(map(sum,p['phases']))==p['program_cycles']
 assert p['front_cycles']+p['program_cycles']+p['completion_cycles']==r['cycles']
 assert p['host_instructions']==m['program_words']
 assert p['requests'][1]==r['fetches'] and p['payload_bytes'][1]==2*m['program_words']
 assert p['payload_bytes'][0]==2*p['requests'][0]
 for owner in (0,1):
  assert p['qpi_states'][owner][5]==4*p['payload_bytes'][owner]
 # This benchmark has exactly one data write (FC result); all other QPI requests read.
 assert sum(p['qpi_states'][0])==35*p['requests'][0]-8
 assert sum(p['qpi_states'][1])==27*p['requests'][1]+4*p['payload_bytes'][1]
 assert sum(p['micro_states'])==sum(p['dma_states'])==sum(p['mem_states'])==sum(p['exec_states'])==r['core_cycles']
 rows.append(dict(case=case.name,dataset=m['dataset'],step=m['step'],result=r,profile=p))
sourcefiles=[ROOT/x for x in (ROOT/'src/sources.f').read_text().splitlines() if not x.startswith('+')]
before=ROOT/'reports/micro_reduction/before_src'
assert all(p.read_bytes()==(before/p.relative_to(ROOT/'src')).read_bytes() for p in sourcefiles)
summary=dict(partition_labels=labels,phase_labels=phases,cases=rows,
             note='Partition uses DMA > memory > EXEC > MICRO > fetch > other priority. Occupancy/state counters overlap, are not additive and do not prove isolated speedups. No functional RTL changes or synthesis.',
             rtl_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sourcefiles})
(OUT/'profile.json').write_text(json.dumps(summary,indent=2)+'\n')
fast=min(rows,key=lambda r:r['result']['core_cycles']);slow=max(rows,key=lambda r:r['result']['core_cycles'])
f=fast['profile'];s=slow['profile']
lines=['# Restored MICRO: full EGRU+FC bottleneck profile','',
'Passive simulation counters only. Functional RTL is byte-identical to the pre-reduction snapshot; no synthesis was run. All 12 full-network numerical results, cycle counts and original bus counters exactly match the saved baseline.','',
'## Measurement boundaries and accounting','',
'- UART front: INPUT/RUN command through the completed input commit, before frontend START.',
'- Program: START through drain, including state initialization, instruction fetch, full EGRU, FC and PSRAM output. Completion: final READY credit reception. The program-phase output store is part of program time, not a second UART numeric output.',
'- Initial host CONFIG and MCU provisioning are excluded. These are twelve selected warm-started frames, not a continuous full-trace throughput average. Time assumes a 50 MHz core and 25 MHz QPI SCK; no timing closure claim.',
'- Every program cycle is assigned exactly once, with priority DMA-read/write → memory access → EXEC → MICRO control → exposed fetch → dispatch/drain. A bucket describes the current blocking/active state; it is not a measured causal speedup. Independent occupancy and state counters may overlap and must not be summed with the partition.',
'- MICRO control/handoff includes emitted address/mode/SYNC instructions, validation, sparse decisions, pointer updates and operand/result handoff gaps after other active operations have been assigned. It is not all useless waiting.',
'- Phase attribution uses the generator’s tagged command stream; a new phase starts when its first instruction is accepted. Fetch preceding that instruction can be charged to the preceding phase. Aggregate totals are exact.','',
'## Fastest and slowest selected frames','',
f"Fast: bishop_{fast['dataset']} step {fast['step']}; slow: bishop_{slow['dataset']} step {slow['step']}.",'',
'| Exclusive program category | Fast ms | Fast % | Slow ms | Slow % |','|---|---:|---:|---:|---:|']
for label,a,b in zip(labels,f['partition'],s['partition']):lines.append(f'| {label} | {a/50000:.3f} | {100*a/f["program_cycles"]:.1f} | {b/50000:.3f} | {100*b/s["program_cycles"]:.1f} |')
lines+=['',f"Program totals: {f['program_cycles']/50000:.3f} / {s['program_cycles']/50000:.3f} ms. UART front is {f['front_cycles']/50000:.3f} / {s['front_cycles']/50000:.3f} ms; completion credit is {f['completion_cycles']/50000:.5f} / {s['completion_cycles']/50000:.5f} ms.",'',
'## Findings','',
f"1. **DMA and its external reads dominate the active frame.** DMA read+write accounts for {100*sum(s['partition'][:2])/s['program_cycles']:.1f}% ({sum(s['partition'][:2])/50000:.3f} ms). The measured data-bus transactions transfer exactly two bytes each; they include initialization/bias/state copies and one final write, not only weights. The slow frame has {s['requests'][0]:,} transactions ({s['payload_bytes'][0]:,} payload bytes), versus {f['requests'][0]:,} in the fast frame.",
'2. **Per-transaction framing is expensive.** A two-byte QPI read uses 24 core cycles for command+address+dummy and 8 for payload, plus 3 select/finish/recovery cycles: 35 controller-active cycles. Thus payload is only 22.9% of controller-active read time. DMA also pays memory/controller handoff and SRAM commit time. This is a transaction-granularity issue in the current controller, not evidence that PSRAM itself requires all this delay.',
f"3. **MICRO instruction sequencing is the second large active-frame component.** Its exclusive control/handoff bucket is {s['partition'][6]/50000:.3f} ms ({100*s['partition'][6]/s['program_cycles']:.1f}%). Keeping loops avoids external instruction inflation, but repeated DATA/ADDR/MEM/EXEC/STORE/SYNC dispatch still costs cycles. This bucket must be inspected state by state before changing it; removing mandatory dependencies would be incorrect.",
f"4. **Instruction fetch creates an almost fixed floor.** {s['requests'][1]:,} fetches carry {s['payload_bytes'][1]:,} instruction bytes. Exposed fetch is {f['partition'][7]/50000:.3f}–{s['partition'][7]/50000:.3f} ms in these two frames: {100*f['partition'][7]/f['program_cycles']:.1f}% of the fast frame, {100*s['partition'][7]/s['program_cycles']:.1f}% of the slow frame. This is largely serial instruction supply, not arbitration contention: measured data-wait-fetch is only about 0.06 ms, and fetch-wait-data is zero in these network cases (both directions are exercised separately by integration tests).",
f"5. **Arithmetic throughput is not the first bottleneck.** EXEC active time is {f['occupancy'][2]/50000:.3f}–{s['occupancy'][2]/50000:.3f} ms ({100*s['occupancy'][2]/s['program_cycles']:.1f}% in the slow frame). Arithmetic widening/pipelining alone cannot remove the larger transfer and sequencing costs.",'',
'## Network phases','', '| Phase | Fast ms | Slow ms |','|---|---:|---:|']
for label,a,b in zip(phases,f['phases'],s['phases']):lines.append(f'| {label} | {sum(a)/50000:.3f} | {sum(b)/50000:.3f} |')
lines+=['',f"Runtime sparse decisions: fast {f['active_columns']:,} active / {f['skipped_columns']:,} skipped columns; slow {s['active_columns']:,} active / {s['skipped_columns']:,} skipped. Counts are tile-column executions, not unique model input features. The slow frame's recurrent phase is {sum(s['phases'][3])/50000:.3f} ms; recurrent state activity explains much of the input-dependent spread.",'',
'## What a burst-only change can and cannot do','',
f"Even an optimistic accounting exercise that deletes *all* DMA read and SRAM write cycles from the slow frame leaves {(s['program_cycles']-sum(s['partition'][:2]))/50000:.3f} ms. This is not a predicted implementation result; it shows that retaining the rest of the schedule while only accelerating DMA cannot reach 20 ms for this case.",
f"For scale, converting every four independent two-byte reads into an eight-byte read would ideally remove 75% of command/address/dummy cycles. For the slow frame, this is at most {(s['requests'][0]-1)*24*.75/50000:.3f} ms before finite tile boundaries, buffering and handoff effects. It does not remove SRAM commit, internal dispatch or arithmetic. No burst modification is implemented or claimed measured here.",'',
'Next investigations in order: DMA framing/burst granularity; MICRO-to-DATA/EXEC command handoff; repeated scalar/state-update instruction supply. Preserve arithmetic order and dependency semantics. Do not start with extra MAC lanes based on this profile.','',
'## All measured frames','', '| Dataset | Step | UART front ms | Program ms | DMA total ms | MICRO control ms | Exposed fetch ms | EXEC active ms |','|---|---:|---:|---:|---:|---:|---:|---:|']
for row in rows:
 p=row['profile'];lines.append(f"| bishop_{row['dataset']} | {row['step']} | {p['front_cycles']/50000:.3f} | {p['program_cycles']/50000:.3f} | {sum(p['partition'][:2])/50000:.3f} | {p['partition'][6]/50000:.3f} | {p['partition'][7]/50000:.3f} | {p['occupancy'][2]/50000:.3f} |")
lines+=['','## Reproduce','', '```sh','make -f test/Makefile.psram_network build fixtures BUILD=/tmp/acc-bottleneck','python3 scripts/run_psram_network.py --binary /tmp/acc-bottleneck/Vtb_psram_network --profile','python3 scripts/summarize_bottleneck.py','```','',
'Counters live in `test/psram_profile.svh`, enabled only by `+PROFILE`/`--profile`. Per-case `profile.json` and `phases.hex` remain alongside the images; the combined report and RTL hashes are `reports/bottleneck/profile.json`. No synthetic zero-latency memory, altered clock divider or arithmetic shortcut was used.']
(ROOT/'docs/bottleneck.md').write_text('\n'.join(lines)+'\n')
print('Verified 12 unchanged full-network runs and exact partitions.')
print('Slow program ms',s['program_cycles']/50000,'DMA ms',sum(s['partition'][:2])/50000,'control ms',s['partition'][6]/50000,'fetch ms',s['partition'][7]/50000)
