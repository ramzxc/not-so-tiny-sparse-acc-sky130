#!/usr/bin/env python3
"""Render the validated queue projections without changing design or measurements."""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/realtime_buffers'
s=json.loads((OUT/'summary.json').read_text())
ds=s['datasets']
lines=['# Current hardware: continuous input and PC buffer scenarios','',
       '**Conclusion:** at 50 MHz, batch 1, the current aligned full EGRU+FC schedule cannot keep up indefinitely with uninterrupted 20 ms inputs. Finite recording followed by delayed processing is feasible in the timing model with enough PC memory. No 100 ms response deadline is imposed in this assessment.', '',
       '## Evidence and boundaries','',
       '- Current not-so-tiny RTL, buffered 1 KiB SRAM, aligned weight scratch, UART input, PSRAM instructions/weights/output. No RTL edits or synthesis for this evaluation.',
       '- 20 existing numerical RTL frames fit the timing model. Sixteen independent low/median/p90/seeded-random frames then match it with **zero cycle error**. All 16 compare all c/y states, both FC values and PSRAM output with the FP8 reference.',
       '- The model is applied to **103,133 real FP8 trace steps** across four Bishop datasets. Whole-trace and queue results below are **projections**, not whole-trace RTL or board measurements.',
       '- Input arrival is every 20 ms; batch 1; no dropped/coalesced inputs. PC obeys UART READY and queues unsent inputs. Results are considered delivered at PSRAM output/completion; downstream PC work is excluded.',
       '- One compact PC record stores 184–187 FP8 input bytes plus eight bytes of timestamp/sequence metadata. Include one in-service frame conservatively. Python list/object overhead, raw sensor samples, model files and OS overhead are not included.',
       '- The internal 1 KiB is network working storage. The reported queue capacity must be in PC RAM/disk; current chip SRAM and the external PSRAM interface do not implement this pending-input queue.',
       '- Reference traces reset at known trial offsets. Real wall-clock trial gaps are absent. The no-gap case concatenates trials; 1 s and 5 s trial gaps below are explicit synthetic scenarios.',
       '- Per-frame RTL fixtures warm-start from the software reference state. Timing includes that state-load sequence. A live recurrent state-carry/reset host program has not been validated end-to-end; these numbers assess service demand, not a complete deployed streaming system.',
       '- 50 MHz core / 25 MHz QPI SCK is assumed, not physical timing signoff. PC scheduling stalls are excluded. A uniform 10% slowdown is a sensitivity check, not a guaranteed bound for other data or hardware.', '',
       '## Validated cycle model','',
       '`program_cycles = base[dataset] + 16352 * active_input + 16096 * active_previous_y + 76 * active_new_y`','',
       f'Bases: `{s["model"]["base_by_dataset"]}`. UART input/completion overhead cycles: `{s["model"]["uart_overhead_cycles_by_dataset"]}`. Divide cycles by 50,000 for milliseconds. The model includes full input/recurrent projections, gates, state update, FC, command fetch and output store.', '',
       '| Dataset | Core mean ms | UART-inclusive mean ms | Service inputs/s | Input rate |',
       '|---|---:|---:|---:|---:|']
for d in ds:lines.append(f'| bishop_{d["dataset"]} | {d["core_mean_ms"]:.3f} | {d["total_mean_ms"]:.3f} | {d["projected_inputs_per_second"]:.2f} | 50/s |')
lines += ['', 'Even removing all UART and the 0.0918 ms warm-state initialization leaves projected core means above 20 ms. Thus host buffering or UART acceleration alone cannot make this current schedule sustainable indefinitely. This does not require each individual frame to finish within 20 ms; the deficit here is sustained average service.', '',
          '## Scenario A: first 10 seconds / first 60 seconds of each actual trace','',
          '| Dataset | 10 s peak PC buffer KiB | 10 s capture drain s | 60 s peak PC buffer KiB | 60 s capture drain s |',
          '|---|---:|---:|---:|---:|']
for d in ds:
    a=d['scenarios']['first_10_seconds'];b=d['scenarios']['first_60_seconds']
    lines.append(f'| bishop_{d["dataset"]} | {a["peak_input_bytes"]/1024:.2f} | {a["drain_after_capture_seconds"]:.2f} | {b["peak_input_bytes"]/1024:.2f} | {b["drain_after_capture_seconds"]:.2f} |')
lines += ['', 'These are trace prefixes, not worst possible 10/60-second intervals. A 256 KiB compact queue fits these four one-minute prefixes, but backlog remains after capture.', '',
          '## Scenario B: one entire dataset, continuously captured','',
          '| Dataset | Capture min | Peak queued records | Peak PC buffer MiB | Drain after capture min |',
          '|---|---:|---:|---:|---:|']
for d in ds:
    q=d['scenarios']['full_continuous']
    lines.append(f'| bishop_{d["dataset"]} | {q["capture_seconds"]/60:.2f} | {q["peak_outstanding_frames"]:,} | {q["peak_input_bytes"]/2**20:.3f} | {q["drain_after_capture_seconds"]/60:.2f} |')
lines += ['', 'Nominally 2 MiB fits each complete dataset. Under the 10% slower sensitivity, the largest peak becomes '+
          f'{max(d["scenarios"]["full_10percent_slower"]["peak_input_bytes"] for d in ds)/2**20:.3f} MiB: '+
          '**4 MiB is a reasonable compact input-queue allocation for these finite sessions**, with several minutes of result delay. This is not an arbitrary-input capacity guarantee.', '',
          '## Scenario C: one hour of uninterrupted capture','',
          'Repeat each real activity trace until 180,000 arrivals. Trial resets/activity patterns repeat; this is a synthetic duration extension, not an actual hour-long recording.', '',
          '| Dataset | Peak PC buffer MiB | Drain after capture min | Peak MiB if 10% slower |',
          '|---|---:|---:|---:|']
for d in ds:
    q=d['scenarios']['one_hour_repeated_trace'];g=d['scenarios']['one_hour_10percent_slower']
    assert g['first_overflow_seconds'] is None
    lines.append(f'| bishop_{d["dataset"]} | {q["peak_input_bytes"]/2**20:.3f} | {q["drain_after_capture_seconds"]/60:.2f} | {g["peak_input_bytes"]/2**20:.3f} |')
lines += ['', '**16 MiB fits all four one-hour projections, including the 10% slowdown.** It buys recording duration, not timely results. The nominal final drain alone is about 24–32 minutes; any finite queue eventually fills if this average deficit persists.', '',
          '| PC capacity | First overflow range across repeated traces |','|---|---|']
for cap in [64*1024,256*1024,1024*1024,8*1024*1024]:
    times=[d['one_hour_buffers'][str(cap)]['first_overflow_seconds'] for d in ds]
    assert all(t is not None for t in times)
    label=f'{cap//1024} KiB' if cap<2**20 else f'{cap//2**20} MiB'
    unit=60 if cap>=2**20 else 1
    lines.append(f'| {label} | {min(times)/unit:.2f}–{max(times)/unit:.2f} {"min" if unit==60 else "s"} |')
lines += ['', 'Overflow means an incoming record no longer fits: stop the source if permitted, spool to disk, or drop data. It does not itself describe a chip arithmetic failure. Continuing to send UART words without obeying READY is not a valid overflow policy.', '',
          '## Scenario D: breaks between actual trial segments','',
          '| Added break after each trial | Peak PC buffer range KiB | Max response range s |',
          '|---|---:|---:|']
for gap in [1000,5000]:
    q=[d['scenarios'][f'trial_gap_{gap}ms'] for d in ds]
    lines.append(f'| {gap/1000:g} s | {min(r["peak_input_bytes"] for r in q)/1024:.2f}–{max(r["peak_input_bytes"] for r in q)/1024:.2f} | {min(r["max_latency_ms"] for r in q)/1000:.2f}–{max(r["max_latency_ms"] for r in q)/1000:.2f} |')
lines += ['', 'A five-second break greatly reduces accumulation on these finite traces, but some individual trials still need more than five seconds to drain. If every trial starts with an empty queue, the largest required drain pause is '+
          f'{max(d["required_gap_to_clear_each_trial_seconds"]["max"] for d in ds):.2f} s. '+
          'To enforce empty-queue trial starts, use completion-driven pauses rather than assume a fixed gap always clears the backlog.', '',
          '## Practical verdict','',
          '- **Uninterrupted sensor processing with bounded long-term lag: insufficient at 50 MHz under this schedule.** Arrivals average 50/s, service averages only 32.6–35.6/s.',
          '- **Finite recording with all inputs preserved and delayed results: capacity is practical on a PC.** Use a bounded compact queue plus overflow detection or durable disk spooling, obey chip credits, and allow the measured drain time. 4 MiB for these full sessions / 16 MiB for the synthetic hour are tested model allocations.',
          '- **Intermittent acquisition:** pauses can make this hardware useful without immediate RTL changes, but the actual acquisition pattern and acceptable response delay determine sufficiency.',
          '- The timing model does not certify live recurrent state carry, board UART reliability, PSRAM electrical timing, PC scheduling or the response tolerance of a BCI application. Those need a separate end-to-end test before a loss-free deployment claim.', '',
          'Reproduce with `python3 scripts/evaluate_realtime_buffers.py`, or `--reuse-holdouts` to reuse the sixteen passing RTL results, then `python3 scripts/report_realtime_buffers.py`. '+
          'Evidence and source hashes: `reports/realtime_buffers/summary.json`; per-frame logs, expected data and profiles: `reports/realtime_buffers/holdouts/`. The queue calculation is checked against independent event accounting and simultaneous finish/arrival semantics.']
(ROOT/'docs/realtime_buffers.md').write_text('\n'.join(lines)+'\n')
print('Report written:',ROOT/'docs/realtime_buffers.md')
