# FP8 / 1 KiB full EGRU + FC performance

The layout and measurements below predate the weight-buffer alignment. See [weight_alignment.md](weight_alignment.md) for the current layout and measured comparison.

For separate front/core/back measurements, see [the consumer report](performance_fp8_consumer.md).

Current not-so-tiny RTL, batch 1, 50 MHz cycle conversion. UART divider 87 (574,713 baud). Input period 20 ms and per-input latency budget 100 ms are assumptions, not dataset timestamps.

## Measured selected frames

| Dataset | Step | Whole step (ms) | MICRO busy (ms) | UART wire-only lower bound (ms) |
|---|---:|---:|---:|---:|
| bishop_0 | 0 | 1134.568 | 19.037 | 773.326 |
| bishop_0 | 100 | 1149.114 | 38.715 | 773.326 |
| bishop_0 | 25519 | 1211.494 | 101.311 | 773.326 |
| bishop_1 | 0 | 1131.871 | 16.261 | 773.360 |
| bishop_1 | 100 | 1133.430 | 22.706 | 773.360 |
| bishop_1 | 23481 | 1205.561 | 95.228 | 773.360 |
| bishop_2 | 0 | 1134.636 | 19.012 | 773.360 |
| bishop_2 | 100 | 1124.793 | 11.861 | 773.360 |
| bishop_2 | 24067 | 1211.862 | 101.558 | 773.360 |
| bishop_3 | 0 | 1130.838 | 15.315 | 773.395 |
| bishop_3 | 100 | 1133.603 | 20.730 | 773.395 |
| bishop_3 | 20253 | 1202.857 | 92.537 | 773.395 |

All 12 cases passed bit-exact comparison of 256 cell states, 256 emitted states, and both FC outputs. Selected service times are 1124.793–1211.862 ms: 56.2–60.6 times the 20 ms arrival period. This schedule cannot sustain the stream or meet a 100 ms deadline, even before external I/O. A PC queue cannot absorb a sustained service-rate deficit.

## Coverage and schedule

For each of four Bishop datasets, test step 0, step 100, and the step maximizing active input plus active previous-output count in the FP8 trace. The latter is a high-activity sample, not a proven worst latency. Reference traces cover all 103,133 dataset steps with trial resets. RTL runs only the 12 selected frames, initialized from the immediately preceding reference states. No full-dataset RTL average or original-model task accuracy is claimed.

Each step includes input Flash-to-SRAM DMA, bias loads, input U/R projections, recurrent U/R/Z projections, sigmoid and reset multiplication, input Z projection, tanh, cell/event/reset updates, and the two-output FC head. All commands enter through physical UART pins with READY credits; weights use pin-level QSPI NOR and the actual 1 KiB SRAM simulation model. SRAM is not preloaded through a backdoor. State/FC readback for validation uses observation only.

SRAM bytes: c 0–255; old y 256–511; new y 512–767; input 768–955; DMA tile/threshold 956–979; U/R/Z gates 980–1003; temporaries 1004–1019; FC 1020–1021; ones 1022–1023. Eight hidden outputs are completed per tile. Preserve old y until all recurrent consumers finish; the old/new buffer roles can swap for a subsequent step. No Flash programs or external state spills occur. This is one valid schedule, not a proof of an optimal schedule.

The MICRO sequencer runs matrix columns autonomously, including burst DMA. Pointwise gates and state updates still require host LOAD/EXEC/STORE instruction sequences. Redundant unchanged address/config fields are omitted, and there are no per-tile host fences. Explicit SYNC protects operand/result dependencies. The timing includes these instruction costs.

## Bottleneck and sensitivity

- input_and_bias: 11.916 ms.
- input_ur: 17.848 ms.
- recurrent: 34.795 ms.
- gates: 234.598 ms.
- input_z: 16.179 ms.
- state: 799.699 ms.
- head: 19.415 ms.
- fence: 0.117 ms.

Phase times partition wall time by the host instruction being supplied, including any wait for the preceding operation. They are not isolated engine costs. MICRO and DMA busy counters overlap; do not add them. The wire-only bound counts 20 UART bits per 16-bit word and excludes READY, compute and stalls.

- Sensitivity only, bishop_0 step 0, divider 8 (6.25 Mbaud): 123.493 ms, bit-exact outputs. The production RTL default was not changed.
- Sensitivity only, bishop_0 step 100, divider 8 (6.25 Mbaud): 143.111 ms, bit-exact outputs. The production RTL default was not changed.
- Sensitivity only, bishop_0 step 25519, divider 8 (6.25 Mbaud): 205.623 ms, bit-exact outputs. The production RTL default was not changed.

First reduce per-element host instruction traffic, e.g. a generic MICRO vector-ALU sequence/loop or locally stored instruction stream, then remeasure. Faster UART alone is insufficient in these tests. High-activity matrix work itself also exceeds the 20 ms interval; investigate tile sizing, state/workspace reuse and weight transfer reuse after command overhead is removed. These are proposed design changes, not measured speedups or area-free promises.

## Limits

Inputs are already present in Flash when measurement begins. Count their DMA into SRAM, but exclude PC/sensor input delivery, board initialization, warm-start state loading and FC return transport. Current UART returns READY, not the numerical FC result. This is a lower bound on end-to-end system latency. 50 MHz is a cycle conversion, not SRAM/logic/board timing closure.

The independent exact-rational E4M3FN oracle supplies arithmetic tables. The model follows egru/sim gate order, using chip hard sigmoid/tanh and separately quantized bias plus recurrent_bias added in FP8. FC adds outputs in ascending hidden index. Numerical behavior differs from the original FP16/true-activation model; task accuracy needs separate evaluation.

## Reproduce

From the repository root, after preparing the Bishop FP8 files:

```sh
python3 scripts/prepare_bishop_fp8.py
make -f test/Makefile.network
python3 scripts/summarize_fp8_network.py
```

For the divider-8 sensitivity, rebuild the same bench with `-GUART_CLKS_PER_BIT=8` into a separate build directory, then use `scripts/run_fp8_network.py --limit 3 --binary <binary> --report-name uart8`. Artifacts are in `reports/fp8_full/`: source/fixture hashes and all measured counters in `summary.json`; per-case command/Flash/expected fixtures and simulation logs; full software reference traces and the arithmetic contract.
