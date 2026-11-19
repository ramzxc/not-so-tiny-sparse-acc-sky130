# Current hardware: continuous input and PC buffer scenarios

**Conclusion:** at 50 MHz, batch 1, the current aligned full EGRU+FC schedule cannot keep up indefinitely with uninterrupted 20 ms inputs. Finite recording followed by delayed processing is feasible in the timing model with enough PC memory. No 100 ms response deadline is imposed in this assessment.

## Evidence and boundaries

- Current not-so-tiny RTL, buffered 1 KiB SRAM, aligned weight scratch, UART input, PSRAM instructions/weights/output. No RTL edits or synthesis for this evaluation.
- 20 existing numerical RTL frames fit the timing model. Sixteen independent low/median/p90/seeded-random frames then match it with **zero cycle error**. All 16 compare all c/y states, both FC values and PSRAM output with the FP8 reference.
- The model is applied to **103,133 real FP8 trace steps** across four Bishop datasets. Whole-trace and queue results below are **projections**, not whole-trace RTL or board measurements.
- Input arrival is every 20 ms; batch 1; no dropped/coalesced inputs. PC obeys UART READY and queues unsent inputs. Results are considered delivered at PSRAM output/completion; downstream PC work is excluded.
- One compact PC record stores 184–187 FP8 input bytes plus eight bytes of timestamp/sequence metadata. Include one in-service frame conservatively. Python list/object overhead, raw sensor samples, model files and OS overhead are not included.
- The internal 1 KiB is network working storage. The reported queue capacity must be in PC RAM/disk; current chip SRAM and the external PSRAM interface do not implement this pending-input queue.
- Reference traces reset at known trial offsets. Real wall-clock trial gaps are absent. The no-gap case concatenates trials; 1 s and 5 s trial gaps below are explicit synthetic scenarios.
- Per-frame RTL fixtures warm-start from the software reference state. Timing includes that state-load sequence. A live recurrent state-carry/reset host program has not been validated end-to-end; these numbers assess service demand, not a complete deployed streaming system.
- 50 MHz core / 25 MHz QPI SCK is assumed, not physical timing signoff. PC scheduling stalls are excluded. A uniform 10% slowdown is a sensitivity check, not a guaranteed bound for other data or hardware.

## Validated cycle model

`program_cycles = base[dataset] + 16352 * active_input + 16096 * active_previous_y + 76 * active_new_y`

Bases: `[422302, 423094, 423094, 423632]`. UART input/completion overhead cycles: `[235657, 238191, 238191, 240725]`. Divide cycles by 50,000 for milliseconds. The model includes full input/recurrent projections, gates, state update, FC, command fetch and output store.

| Dataset | Core mean ms | UART-inclusive mean ms | Service inputs/s | Input rate |
|---|---:|---:|---:|---:|
| bishop_0 | 24.667 | 29.380 | 34.04 | 50/s |
| bishop_1 | 25.926 | 30.690 | 32.58 | 50/s |
| bishop_2 | 23.873 | 28.637 | 34.92 | 50/s |
| bishop_3 | 23.283 | 28.097 | 35.59 | 50/s |

Even removing all UART and the 0.0918 ms warm-state initialization leaves projected core means above 20 ms. Thus host buffering or UART acceleration alone cannot make this current schedule sustainable indefinitely. This does not require each individual frame to finish within 20 ms; the deficit here is sustained average service.

## Scenario A: first 10 seconds / first 60 seconds of each actual trace

| Dataset | 10 s peak PC buffer KiB | 10 s capture drain s | 60 s peak PC buffer KiB | 60 s capture drain s |
|---|---:|---:|---:|---:|
| bishop_0 | 25.12 | 4.03 | 159.19 | 24.33 |
| bishop_1 | 32.04 | 4.96 | 189.80 | 29.43 |
| bishop_2 | 22.99 | 3.60 | 154.93 | 22.15 |
| bishop_3 | 30.85 | 5.50 | 166.05 | 26.68 |

These are trace prefixes, not worst possible 10/60-second intervals. A 256 KiB compact queue fits these four one-minute prefixes, but backlog remains after capture.

## Scenario B: one entire dataset, continuously captured

| Dataset | Capture min | Peak queued records | Peak PC buffer MiB | Drain after capture min |
|---|---:|---:|---:|---:|
| bishop_0 | 10.44 | 9,537 | 1.746 | 4.90 |
| bishop_1 | 8.32 | 8,475 | 1.560 | 4.45 |
| bishop_2 | 8.51 | 7,551 | 1.390 | 3.68 |
| bishop_3 | 7.10 | 6,005 | 1.117 | 2.88 |

Nominally 2 MiB fits each complete dataset. Under the 10% slower sensitivity, the largest peak becomes 2.107 MiB: **4 MiB is a reasonable compact input-queue allocation for these finite sessions**, with several minutes of result delay. This is not an arbitrary-input capacity guarantee.

## Scenario C: one hour of uninterrupted capture

Repeat each real activity trace until 180,000 arrivals. Trial resets/activity patterns repeat; this is a synthetic duration extension, not an actual hour-long recording.

| Dataset | Peak PC buffer MiB | Drain after capture min | Peak MiB if 10% slower |
|---|---:|---:|---:|
| bishop_0 | 10.520 | 28.05 | 12.487 |
| bishop_1 | 11.474 | 32.01 | 13.485 |
| bishop_2 | 9.975 | 25.88 | 12.040 |
| bishop_3 | 9.645 | 24.36 | 11.838 |

**16 MiB fits all four one-hour projections, including the 10% slowdown.** It buys recording duration, not timely results. The nominal final drain alone is about 24–32 minutes; any finite queue eventually fills if this average deficit persists.

| PC capacity | First overflow range across repeated traces |
|---|---|
| 64 KiB | 20.34–25.94 s |
| 256 KiB | 82.88–98.76 s |
| 1 MiB | 5.34–6.41 min |
| 8 MiB | 41.68–49.73 min |

Overflow means an incoming record no longer fits: stop the source if permitted, spool to disk, or drop data. It does not itself describe a chip arithmetic failure. Continuing to send UART words without obeying READY is not a valid overflow policy.

## Scenario D: breaks between actual trial segments

| Added break after each trial | Peak PC buffer range KiB | Max response range s |
|---|---:|---:|
| 1 s | 393.62–1086.94 | 63.74–174.83 |
| 5 s | 58.08–71.62 | 10.35–13.04 |

A five-second break greatly reduces accumulation on these finite traces, but some individual trials still need more than five seconds to drain. If every trial starts with an empty queue, the largest required drain pause is 13.02 s. To enforce empty-queue trial starts, use completion-driven pauses rather than assume a fixed gap always clears the backlog.

## Practical verdict

- **Uninterrupted sensor processing with bounded long-term lag: insufficient at 50 MHz under this schedule.** Arrivals average 50/s, service averages only 32.6–35.6/s.
- **Finite recording with all inputs preserved and delayed results: capacity is practical on a PC.** Use a bounded compact queue plus overflow detection or durable disk spooling, obey chip credits, and allow the measured drain time. 4 MiB for these full sessions / 16 MiB for the synthetic hour are tested model allocations.
- **Intermittent acquisition:** pauses can make this hardware useful without immediate RTL changes, but the actual acquisition pattern and acceptable response delay determine sufficiency.
- The timing model does not certify live recurrent state carry, board UART reliability, PSRAM electrical timing, PC scheduling or the response tolerance of a BCI application. Those need a separate end-to-end test before a loss-free deployment claim.

Reproduce with `python3 scripts/evaluate_realtime_buffers.py`, or `--reuse-holdouts` to reuse the sixteen passing RTL results, then `python3 scripts/report_realtime_buffers.py`. Evidence and source hashes: `reports/realtime_buffers/summary.json`; per-frame logs, expected data and profiles: `reports/realtime_buffers/holdouts/`. The queue calculation is checked against independent event accounting and simultaneous finish/arrival semantics.
