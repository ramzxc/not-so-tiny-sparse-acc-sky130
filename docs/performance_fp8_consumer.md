# FP8 consumer: front / core / back

Boundary: input available in external Flash → internal input DMA, complete EGRU and FC → two FC bytes committed to external Flash. Ignore all PC work after result emission. Batch 1, 1 KiB SRAM, same eight-neuron schedule as the [full-network benchmark](performance_fp8_1k.md).

## Three separately characterized costs

| Part | Result at 50 MHz | Meaning |
|---|---|---|
| Front: current UART command supply | See measured marginal overhead below (about 1.11 seconds) | Actual UART/READY versus ideal command availability; excludes unimplemented PC-to-input-Flash delivery |
| Core | 13.854–103.551 ms in 20 RTL frames | Complete input DMA + EGRU state update + FC; ideal command availability |
| Back: result Flash commit | 6.0091 ms | Both output bytes verified; two program operations at 3 ms each, plus command/bus/polling cycles |

Core-only testing injects commands at the existing instruction FIFO input and respects its capacity and downstream backpressure. All functional compute/memory RTL remains active. This is a controlled isolation experiment; the chip does not currently contain a local instruction stream that achieves it. In both modes all 256 c values, 256 y values and both FC values are compared with the FP8 reference. Flash result bytes are also compared. Twenty ideal-feed cases and three UART-fed complete-output cases passed.

The output timing uses the 3 ms maximum tPP from the [Winbond W25Q128JV Revision J datasheet, p.65](https://www.mouser.com/datasheet/2/949/Winbond_Electronics_Corporation_09_06_2024_W25Q128-3501276.pdf). Current RTL programs one byte per transaction, hence two programs. This is a conservative simulated Flash condition, not a measured board latency. Erased output storage is assumed available; erase/recycling is outside this finite log test. No numerical-result UART transmitter exists in the current RTL, so UART output is not reported as implemented.

## Additive comparison without double counting

Front below is **effective added latency** = UART-fed total − ideal-fed total. It already accounts for overlap and includes the commands that initiate output writes. It is not UART wire time plus an independent core time. Adding wire duration and busy counters directly would double-count overlaps.

| Bishop 0 step | Front extra (ms) | Core (ms) | Back (ms) | Sum / measured total (ms) |
|---|---:|---:|---:|---:|
| 0 | 1114.246 | 21.029 | 6.009 | 1141.284 |
| 100 | 1109.114 | 40.707 | 6.009 | 1155.830 |
| 25519 | 1108.898 | 103.304 | 6.009 | 1218.211 |

## Sustained input consumption

At 20 ms arrivals, a frame occasionally taking more than 20 ms can be buffered. Sustained average service time must nevertheless stay below 20 ms, and queueing must fit the 100 ms latency allowance.

An activity-count timing model matches all 12 calibration RTL cases and all eight independent held-out RTL cases exactly (zero cycle error):

`core_cycles = base[dataset] + 27648 * active_input + 23616 * active_previous_y + 177 * active_new_y`

Bases are 272712, 273630, 273630, 274740 for Bishop 0–3. Held-outs use one median-activity step and one seeded random step per dataset. The following averages apply that calibrated model to all 103,133 steps of the complete FP8 software trace; they are **projections**, not full-dataset RTL measurements.

| Dataset | Projected core mean at 50 MHz (ms) | Average-rate minimum (MHz) | 20% time headroom (MHz) |
|---|---:|---:|---:|
| bishop_0 | 31.086 | 77.71 | 97.14 |
| bishop_1 | 32.894 | 82.23 | 102.79 |
| bishop_2 | 29.901 | 74.75 | 93.44 |
| bishop_3 | 29.108 | 72.77 | 90.96 |

The core alone is therefore not sustainable at 50 MHz under this schedule, even with ideal commands. Average-rate thresholds have zero slack; the margin column targets 16 ms rather than 20 ms. These are arithmetic clock equivalents, not achievable-clock claims. Burst activity and the 100 ms queueing limit can require considerably more headroom than the mean suggests.

Projected FIFO queue recurrence: `finish[i] = max(arrival[i], finish[i-1]) + service[i]`, with arrivals every 20 ms, no inter-trial gaps, no dropped/coalesced inputs. Software states reset at trial offsets; extra RTL reset commands are omitted. Clock sweeps scale logic/read cycles only; the two 3 ms Flash program waits stay fixed.

| Dataset | Core-only minimum clock for all projected latencies ≤100 ms (MHz) | Core + worst-tPP Flash (MHz) |
|---|---:|---:|
| bishop_0 | 182.24 | 257.27 |
| bishop_1 | 173.97 | 246.21 |
| bishop_2 | 177.06 | 249.55 |
| bishop_3 | 168.16 | 232.26 |

These queue thresholds are model-only lower estimates for the stated schedule and timing assumptions, excluding front-end and trial-reset overhead; they are not physical signoff. Finite selected-frame bit-exact tests do not prove loss-free indefinite operation. At 50 MHz, the average deficit already proves that an indefinitely buffered stream cannot be sustained by this schedule.

## Reproduce and artifacts

Prepare FP8 data and software reference traces as described in the full-network report, then run:

```sh
make -f test/Makefile.consumer
```

`reports/fp8_full/consumer_summary.json` stores measured costs, cycle model, queue projections and source hashes. `consumer_cases.json` and `consumer_holdout_cases.json` identify fixtures; each case retains command/Flash/expected data and result logs. Numerical validation uses the chip FP8/hard-activation reference, not original FP16 model accuracy. No P&R/timing closure was performed.
