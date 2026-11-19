# MICRO reduction: historical rolled-back experiment

**Rolled back at the user’s request. Current RTL has the original MICRO and
16-bit program count. The numbers below describe the discarded revision, not
the current design. Experimental code is archived under
`reports/micro_reduction/reverted_stage/`; the reproduction commands at the end
require that matching experimental snapshot.**

Only not-so-tiny changed. No synthesis was run for this stage. The same FP8 EGRU+FC selected frames were checked against the reference, including all 256 c elements, all 256 y elements, both FC elements and the final PSRAM output bytes. All 12 cases pass.

## What changed

- The 32-state MICRO controller is excluded from the active sources and top-level path. Its original file remains marked historical for comparison. Generic column/batch/DMA scheduling is expanded by `scripts/lower_micro.py` before loading PSRAM.
- The frontend handles only a runtime sparse forward skip. It waits for operand completion and uses the existing two-lane zero mask, PC, remaining count and instruction buffer. No loop counter, batch mask RAM or second buffer was added.
- Programs larger than 65535 words require 23-bit program and remaining counts: CONFIG now has separate low16/high7 count words. Old UART CONFIG and MICRO binary programs must be regenerated.
- Source-declared MICRO sequential state totals 210 bits, removed from the active build. Widening two frontend counts adds 14 bits: net 196 fewer declared state bits. This is **not** a measured flop/cell-area reduction; skip add/subtract, bounds and selection logic still have area costs.
- The software compiler removes redundant address/mode commands within straight-line regions and invalidates assumptions at branch joins. FP8 arithmetic and accumulation order are unchanged.

## Same-boundary cycle comparison

50 MHz below is a conversion of RTL cycle counts, not timing closure. Program time starts at frontend START and includes warm-state initialization, instruction fetch, input consumption, all EGRU operations, FC and PSRAM output. Total adds actual UART input transfer/credits and final completion credit. Initial UART configuration and MCU Flash-to-PSRAM provisioning are outside both measurements. These are selected warm-started frames, not a continuous trace average; the initialization of each frame remains identical between revisions.

| Dataset | Step | Old program ms | New program ms | Ratio | Old total ms | New total ms | Old / new fetch requests |
|---|---:|---:|---:|---:|---:|---:|---:|
| bishop_0 | 0 | 28.691 | 93.911 | 3.27x | 33.405 | 98.624 | 5563 / 61980 |
| bishop_0 | 100 | 52.880 | 160.997 | 3.04x | 57.593 | 165.710 | 5563 / 99103 |
| bishop_0 | 25519 | 125.120 | 363.505 | 2.91x | 129.833 | 368.218 | 5563 / 211671 |
| bishop_1 | 0 | 25.729 | 85.529 | 3.32x | 30.493 | 90.293 | 5563 / 57316 |
| bishop_1 | 100 | 33.958 | 108.173 | 3.19x | 38.722 | 112.937 | 5563 / 69825 |
| bishop_1 | 23481 | 118.566 | 344.848 | 2.91x | 123.329 | 349.612 | 5563 / 201228 |
| bishop_2 | 0 | 28.692 | 93.918 | 3.27x | 33.456 | 98.681 | 5563 / 62004 |
| bishop_2 | 100 | 21.519 | 73.354 | 3.41x | 26.282 | 78.117 | 5563 / 50458 |
| bishop_2 | 24067 | 126.244 | 366.718 | 2.90x | 131.008 | 371.482 | 5563 / 213477 |
| bishop_3 | 0 | 24.636 | 82.481 | 3.35x | 29.450 | 87.295 | 5564 / 55653 |
| bishop_3 | 100 | 31.051 | 100.363 | 3.23x | 35.865 | 105.177 | 5564 / 65563 |
| bishop_3 | 20253 | 116.213 | 338.476 | 2.91x | 121.027 | 343.290 | 5564 / 197781 |

## Interpretation

Program service time rises to 73.354–366.718 ms in these cases. Every measured frame exceeds the 20 ms arrival interval, even excluding UART input time. This version cannot sustainably consume that selected workload at 50 MHz; upstream buffering postpones overflow but cannot fix the service-rate deficit. A 100/120 ms deadline is a separate requirement and does not relax the long-term input rate.

The dominant new cost is reading the expanded instructions from the same PSRAM bus used by weights. Sparse guards jump past inactive work without fetching the entire skipped body, but active columns now fetch their DMA/load/execute/store instructions instead of generating them internally. Replacing MICRO therefore has a real throughput tradeoff. A compact repeat/template mechanism could recover command bandwidth with some hardware state; that is a separate design decision, not implemented here.

| Dataset | Old program bytes | New program bytes |
|---|---:|---:|
| bishop_0 | 44,502 | 3,553,666 |
| bishop_1 | 44,504 | 3,562,380 |
| bishop_2 | 44,504 | 3,562,380 |
| bishop_3 | 44,506 | 3,579,148 |

Expanded programs start at 0x100000 and fit within PSRAM A alongside the tested data images. Larger networks are subject to the same 8 MiB capacity, so fitting these models is not an arbitrary-network capacity guarantee.

## Functional scope and differences

- Seven current cocotb tests pass: four UART/PSRAM integration tests and three frontend tests. Integration includes generic batches 1/2/3/4/8/128, direct and DMA schedules, dense/sparse mode, signed zero and NaN, replay, hazards, invalid bounds, UART framing and reset. Frontend tests include both guard lanes, taken/not-taken skips, buffered/cross-boundary/end targets, overrun faults, backpressure, operand fencing, 4095-word skips and a 70001-word program.
- For batch 1, a zero skips weight DMA, arithmetic and writes. For batch >1, DMA is unconditional once per column; per-sample zero guards still suppress arithmetic and output writes. The former whole-batch all-zero DMA suppression is deliberately moved out with the hardware batch scan. Arithmetic results are preserved; transaction counts are not.
- Existing SRAM, FP8 math, DATA and DMA implementations are unchanged in this stage. Numeric UART output and physical board boot/timing are still outside this evaluation.

## Reproduce

```sh
make -C test
make -C test -f Makefile.program
make -f test/Makefile.psram_network
python3 scripts/summarize_micro_reduction.py
```

The comparison script reads the saved pre-change `reports/micro_reduction/before.json` and current per-case results. It never runs synthesis. Source hashes, copied test XML, the before-RTL snapshot and machine-readable measurements live under `reports/micro_reduction/`. See [interface](psram_stream.md) and [host sender](../scripts/psram_stream_host.py).
