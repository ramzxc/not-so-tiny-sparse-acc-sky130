# Sustainable stream experiment at 50 MHz

Baseline checkpoint: `0350439`, branch `checkpoint/no-pc-buffer-optimized`, annotated tag `checkpoint-no-pc-buffer-0350439`. The older PC-buffered checkpoint remains unchanged. Experiment branch: `experiment/sustainable-stream`.

**Result: all four recorded Bishop activity traces have bounded backlog in the final nominal repeated-trace model.** This uses 20 ms arrivals, the existing 4 MiB external PSRAM queue and an additional 0.30 ms input-queue service budget per frame. It is not a full-trace RTL/live-recurrence test or physical timing signoff. No 100 ms response deadline is imposed.

## Staged changes

1. Shared EXEC skips unused stages: overwrite MUL bypasses the add stage; ADD/SUB bypass multiply; ACT_NOP publishes the raw rounded result without two activation cycles. Raw accumulator semantics, FP8 rounding and sparse behavior are preserved. The multiplier and adders are still shared.
2. SRAM read begins on validated request acceptance, instead of spending a separate address-staging cycle. The macro output still has the original falling-edge-to-next-rising-edge capture interval.
3. MICRO STORE itself waits for idle units/latest EXEC result instead of issuing a separate SYNC. SRAM accumulation feeds the final lane directly to the macro on the existing shared-adder result; the completed SRAM write can retire at the next rising edge while accepting another request.
4. Compact SRAM commands present their already-encoded address/mode and held result directly to the memory interface on acceptance, bypassing DATA SEND. Stalled commands do not issue requests, sparse skips issue none, and old write/accumulate flags cannot leak into a new read.

No new payload storage, arithmetic units or architectural register bits are added. There are new control/data mux paths. Their cell area and timing impact is unmeasured: **no synthesis or PNR was run**, and the previous physical-fit/50 MHz timing results do not sign off this RTL.

## Program processing mean, milliseconds at 50 MHz

These times include the complete EGRU/FC computation, command fetch, weights and result store. The historical benchmark field is called `core_cycles`, but it includes the program frontend too; it is not exclusively the compute-core folder. UART input/completion overhead is excluded from these program means.

| Dataset | Checkpoint | Stage 1 | Stage 2 | Stage 3 | Final | Reduction |
|---|---:|---:|---:|---:|---:|---:|
| Bishop 0 | 23.067 | 21.451 | 20.405 | 19.231 | 18.188 | 21.15% |
| Bishop 1 | 24.262 | 22.529 | 21.424 | 20.161 | 19.058 | 21.45% |
| Bishop 2 | 22.307 | 20.770 | 19.762 | 18.646 | 17.641 | 20.92% |
| Bishop 3 | 21.741 | 20.264 | 19.284 | 18.212 | 17.235 | 20.73% |

Each stage fits its own timing model on 20 full-network RTL cases and validates 16 independent holdouts. All 144 staged cases match the reference c/y states, FC outputs and PSRAM output, with zero cycle prediction error on the 36 cases of each stage. Means project these models onto 103,133 recorded activity steps.

## Repeated traces and input-queue stability

The service estimate adds **0.30 ms/frame** to final program time for queue transport/interference and overlaps UART reception with execution. This is an explicit transport budget sensitivity, not a proven bound for all traffic. Actual two-case concurrent tests below support the scale of that allowance. The model conservatively counts the in-service input against PSRAM capacity even though its slot is released before compute completes.

| Dataset | Mean including 0.30 ms | Peak slots, repeats 1 / 2 / 3 | Largest queue KiB | Work remaining at period end, repeats 1 / 2 / 3 (s) |
|---|---:|---|---:|---|
| Bishop 0 | 18.488 | 233 / 233 / 233 | 58.25 | 0.129 / 0.129 / 0.129 |
| Bishop 1 | 19.358 | 253 / 289 / 289 | 72.25 | 5.634 / 5.634 / 5.634 |
| Bishop 2 | 17.941 | 194 / 194 / 194 | 48.50 | 0.144 / 0.144 / 0.144 |
| Bishop 3 | 17.535 | 184 / 184 / 184 | 46.00 | 1.582 / 1.582 / 1.582 |

The worst modeled peak is **289 slots = 72.25 KiB**, versus 16,384 slots / 4 MiB available. Some bursts still create seconds of response lag. Period-end backlog repeats rather than increasing each period: this is bounded queueing, not every frame finishing in 20 ms or a guarantee of zero latency.

The heaviest mean including the budget is **19.358 ms**, leaving about **0.642 ms / 3.2%** of a 20 ms interval. In the harsher scenario (program service 10% slower, plus 0.30 ms), Bishop 0 and 1 again accumulate indefinitely; Bishop 2 and 3 remain stable. Thus nominal stability is supported for these traces, but there is not 10% universal throughput margin.

Finite periodic stability follows from negative total service-minus-arrival time over a period, and the three-repeat event simulation checks the resulting bounded queue. Traces concatenate trial resets with no unrecorded wall-clock pauses; the activity trajectory comes from the software reference. A live recurrent-state-carry program and real sensor workload still need end-to-end validation.

## Concurrent UART plus complete network RTL

The producer sends eight frames per case, every 20 ms at the divider-87 UART rate, without waiting for READY. The program image is below the reserved queue at 0x300000. All sixteen frames match the numerical reference and are retained without a PC backlog. These are repeated warm-start fixtures, not the full recorded trajectory.

| Fixture | First response ms | Last response ms | Peak pending PSRAM frames |
|---|---:|---:|---:|
| psram_bishop_2_step_100 | 13.891 | 13.891 | 1 |
| psram_bishop_2_step_24067 | 53.706 | 266.800 | 5 |

Repeating only the slow fixture still exceeds 20 ms average, so it accumulates. This does not contradict the bounded full-trace model, which includes quieter input periods. It also means the design is not sustainable for arbitrary worst-case event density.

## Verification and reproduction

- EXEC exact-reference tests: 3/3, including exhaustive activation inputs, sparse/scalar cases, held outputs and execution snapshots.
- SRAM backend tests: 2/2, including all vector slots, row preservation, accumulation, boundary rejection, reset and back-to-back requests.
- MICRO tests: 5/5, including generic batches, randomized stalls and a directed check that STORE waits for the newest EXEC result.
- Legacy top-level integration: 4/4. Raw-input queue stress: 3/3.
- DATA directed test: pass; includes retirement, stalls, no duplicate direct requests and no stale accumulate mode on reads.
- Verilator lint: no combinational-loop, latch or multiple-driver findings.
- All comparisons retain FP8 precision, numerical order, network dimensions and 50 MHz timing assumptions.

Use `test/Makefile.psram_network` to build each stage binary, then `scripts/evaluate_sustainable_stream.py --binary BINARY --out reports/sustainable_stream/STAGE`. The script requires the previous 36-case fixture catalog and measured checkpoint timing. `--reuse` reprojects saved measurements. Raw stage summaries and binary/source hashes are under `reports/sustainable_stream/stage1..stage4/`.

The stage-4 timing binary predates whitespace-only formatting cleanup; its exact source snapshot is under `stage4/source_snapshot/`. Final integration/concurrent binaries were built after that cleanup. Current source hashes and regression result files are recorded in the top-level experiment report directory.

The checkpoint remains at 0350439; this candidate is isolated on the experiment branch. Next validation should prioritize mapped area, the newly shortened data/control paths at 50 MHz, and a continuous recurrent-state stream. Do not claim physical timing closure from these RTL results.
