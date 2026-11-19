# FP8 core bottleneck profile

Exclusive cycle counters added to the consumer testbench only. All 12 selected Bishop RTL frames still match reference states/FC/Flash output, with identical total cycles to the earlier runs. No functional RTL optimization is included.

## Representative frame: Bishop 0, step 100

50 MHz, ideal command availability, input DMA through full EGRU+FC: **40.707 ms**. This is an illustrative frame, not the dataset mean.

| Exclusive core category | ms | Percent |
|---|---:|---:|
| dma_read | 15.7554 | 38.70% |
| dma_sram_commit | 3.2730 | 8.04% |
| micro_weight_load | 5.3084 | 13.04% |
| micro_exec_sequence | 4.2467 | 10.43% |
| micro_accumulate_store | 6.9009 | 16.95% |
| micro_input_scan | 3.2358 | 7.95% |
| micro_dma_setup | 0.5194 | 1.28% |
| micro_validation | 0.2259 | 0.55% |
| non_micro | 1.2414 | 3.05% |

Across the 12 selected frames, DMA occupies 37.4–50.0% of core time. EXEC busy occupies 6.8–8.8%.

DMA busy is attributed first; remaining MICRO cycles are grouped by FSM state. Weight-load and accumulate-store buckets include their command/address and synchronization overhead, not just SRAM macro access. EXEC-sequence includes instruction dispatch and waiting; the independent EXEC busy counter measures actual unit occupancy. Orthogonal QSPI/SRAM/EXEC counters overlap these categories and must not be added to them.

## Why DMA is expensive despite burst support

This frame issues 3,440 read bursts for 54,550 bytes: 15.86 bytes/burst on average. Weight tiles are generally 8/16/24 bytes. A tile retains CS across its bytes, but the next column/tile starts another transaction.

Measured DMA decomposition (the same identity holds in all 12 profiles):

`DMA cycles = 118 × number_of_bursts + 10 × number_of_bytes`

- Transaction/status/header overhead: 8.1184 ms (19.94% of core).
- Actual quad payload shifts: 4.3640 ms (10.72% of core).
- Byte/vector delivery and read-side handshake: 3.2730 ms.
- SRAM commit side of DMA: 3.2730 ms.

Thus the physical Flash payload rate alone is not the main limit. Status/address overhead and per-byte/per-two-byte handoffs consume substantial time. These identities characterize this controller/profile; they are not universal Flash timing constants.

## Improvement order, retaining FP8 operation order

1. **Small sequencer simplifications first.** In validated auto-DMA SRAM paths, avoid re-emitting an already-zero ADDR high word and unchanged DATA mode per two-byte vector. Preserve Flash-input and ordinary MICRO cases. W_HI/A_HI account for two command cycles per vector; eliminating both in this representative path has a simple upper bound of 53,084 cycles = 1.062 ms (2.61%), not the required overall speedup. This is a candidate, not a verified patch.
2. **Reduce DMA handoffs / exploit 64-bit SRAM rows.** The macro row is eight bytes, but the current path commits two bytes at a time, reading the row first to preserve other lanes. Assemble aligned complete rows and commit once; retain a correct merge path for unaligned heads/tails. Reduce byte request/response bubbles. Investigate reusing the existing row register before allocating a new buffer. Savings need RTL validation; control and storage cost are not assumed zero.
3. **Reduce repeated SRAM weight loads and accumulator read-modify-writes.** Each two-lane product is stored and accumulated back into SRAM, then the next column repeats the sequence. A row cache or retained tile accumulator could reduce this traffic, but needs flush/coherence rules and extra state. Preserve rounded FP8 multiply-then-add and column order; fused MAC or reordered reduction would change results.
4. **Lengthen useful Flash bursts where storage/schedule permits.** Larger output tiles reduce header count; the current 1 KiB layout is full, so this requires workspace reuse or more storage. Sparse columns and U/R-versus-Z dependencies prevent simply joining arbitrary adjacent requests. Larger SRAM is a real area tradeoff.

Adding arithmetic lanes is not the first target: EXEC is busy for only about 8.3% of this representative core execution. Even making just that occupancy disappear would save at most about 8.3% of the measured schedule; SRAM accumulation arithmetic and transfers would remain. Pipelining/overlap would be a separate architectural change with separate costs.

## Reproduce

```sh
make -f test/Makefile.consumer build
python3 scripts/run_fp8_network.py --cases consumer_cases.json --jobs 3 --binary /tmp/acc-fp8-consumer/Vtb_fp8_consumer --report-name profile
python3 scripts/summarize_fp8_profile.py
```

Per-cycle attribution is in `test/tb_fp8_consumer.sv`; raw JSON counters and logs are under each `reports/fp8_full/consumer_*` case. See [consumer boundary and timing assumptions](performance_fp8_consumer.md).
