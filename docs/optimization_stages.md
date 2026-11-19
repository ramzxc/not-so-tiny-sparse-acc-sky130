# Staged optimization: area and complete-network performance

User-authorized staged synthesis and implementation. All five revisions are preserved under `reports/optimization_stages/`, including source/test/script snapshots, measured cases and synthesis reports. No commits, submission artifacts, floorplan or PDN changes were made. Final functional RTL matches stage 3; subsequent source edits only clarify comments.

## Results

All stages match the reference for 256 c states, 256 y states, both FC values and final PSRAM output in the same twelve Bishop frames. Times below are RTL cycles converted at 50 MHz; program time includes warm-state setup, instruction fetch, all EGRU/FC operations and output store. Total additionally includes UART input/credits and completion credit. Initial CONFIG and MCU provisioning are excluded.

| Stage | Logic area µm² | SRAM area µm² | Total area µm² | Program ms, min–max | UART-to-completion ms, min–max |
|---|---:|---:|---:|---:|---:|
| Baseline | 55,562.0 | 180,155.7 | 235,717.8 | 21.519–126.244 | 26.282–131.008 |
| Row DMA | 56,195.1 | 180,155.7 | 236,350.9 | 18.200–89.737 | 22.964–94.501 |
| Skip redundant high | 56,271.5 | 180,155.7 | 236,427.2 | 17.954–86.769 | 22.718–91.533 |
| Compact MICRO commands | 56,783.2 | 180,155.7 | 236,938.9 | 17.462–80.833 | 22.226–85.597 |
| Compact stored program | 56,783.2 | 180,155.7 | 236,938.9 | 14.334–77.704 | 19.098–82.468 |

Final vs baseline: logic **+2.20%** (+1221.2 µm²), total **+0.52%**. Worst selected program time decreases **38.45%**. The SRAM is unchanged. Stage 3 has the same RTL and independently reproduced mapped area as stage 2b; its gain is software instruction compaction.

| Increment | Additional logic µm² | Reduction of worst program time ms |
|---|---:|---:|
| Row DMA | +633.1 | 36.507 |
| Skip redundant high | +76.3 | 2.968 |
| Compact MICRO commands | +511.7 | 5.936 |
| Compact stored program | +0.0 | 3.129 |

## Interpretation / practical stopping point

Every tested increment improves throughput with a small mapped-area increase, and stored-program compaction costs no further hardware area. No area/performance knee was reached within these candidates. Keep the final implementation as the tested candidate; retain the snapshots if a narrower change is preferred. This is not proof that a larger prefetch cache or extra compute lanes would be worthwhile; neither was added.

The final worst selected frame is still 77.704 ms before UART input. The fastest total is 19.098 ms, but that does **not** establish sustained 20 ms input service across the data. These are selected frames, not a full-trace mean/worst-case guarantee. More work remains for the original continuous-real-time target.

## Physical and timing limits

- DC uses the same SKY130 HD and 1 KiB SRAM libraries, hierarchy retention and 20 ns clock for every stage. Reports are mapped-cell comparisons, not placed/routed area.
- The local core rectangle is 293,766.7 µm². Subtracting the macro gives 113,611.0 µm²; final logic occupies about 50.0% of that nominal remainder. This is only an area screen: routing, halos, PDN, placement fragmentation and later buffers are excluded.
- There is a pre-existing concrete floorplan issue: the macro LEF is 840.455 × 214.355 µm, while config places its lower-left y at 19.135 µm. Its top is 233.490 µm, exceeding the local 8×2 die height 225.760 µm. Fixing placement/PDN is separate work; the placement was not changed here. Mapped area alone cannot decide the final tapeout limit.
- Overall reported setup slack is negative because existing input and output delays are each 20 ns while the comparison clock is 20 ns. The worst path is reset input to output enable; those numbers do not establish the internal Fmax. Constraints were held identical to keep the area comparison fair. Board I/O/reset timing still needs a real constraint/signoff pass.
- Read-only register-to-register timing on saved mapped netlists gives minimum setup slack 6.18 ns (baseline) and 5.72 ns (final) at 20 ns. This is pre-layout, ideal-clock, TT analysis; it is useful internal evidence but not a routed/PVT/board 50 MHz guarantee.

## Implemented behavior

1. DMA copies 1..4 vectors per SRAM-row-bounded QPI read, merges partial rows into the existing write_word buffer and commits once per chunk. Full rows avoid the old-row read. Source/count/destination stay stable until commit; complete span checking, exclusive ownership, reset and errors remain. No extra payload buffer or SRAM macro was added.
2. Auto-DMA/SRAM-input MICRO skips redundant high-address commands and then uses compact SRAM weight-load/result-accumulate operations. Other paths retain their generic ordinary instruction behavior; batch support and sparse column skipping remain.
3. The stored-program compiler folds safe contiguous SRAM setup sequences, keeps every dependency fence and arithmetic operation, and invalidates address knowledge after MICRO_RUN. The typical program decreases from 22,252 to 12,711 words; four-word fetch requests decrease from 5,563 to 3,178.
- Canonical FFFF SYNC is preserved. Former noncanonical opcode-111 SYNC aliases E000..F7FF are repurposed for compact SRAM operations. This encoding extension must be reflected in tools; see [interface](psram_stream.md). UART CONFIG framing and the 16-bit program count are unchanged.
- Boot must select PSRAM linear burst mode before releasing the bus. Wrapped mode is not a substitute for arbitrary-address linear transfers. Maximum observed CS-low remains 1.14 µs at 50 MHz in every stage.

## Validation

Final evidence includes 12 cocotb tests across integration, MICRO, DMA, memory and arbiter suites; four compiler unit tests; native DATA post-increment verification; and twelve complete-network comparisons at every stage. Integration cases cover generic batch 1/3/4; sequencer tests include batch 128 and external-input fallbacks. Added cases cover all compact scalar subcodes, signed zero/NaN, 255-vector copies, unaligned sources, every SRAM vector slot, partial-row neighbor preservation, last SRAM row, reset before commit, backpressure and invalid spans.

The expanded integration test initially exposed an oracle mistake that converted a dense negative-zero product to positive zero. The oracle was corrected to the existing overwrite-MUL semantics; no arithmetic RTL was changed. Final lint passes with only the existing 65-bit macro-model X-width warning.

## Reproduce and inspect

```sh
make -C test
make -C test -f Makefile.micro
make -C test -f Makefile.dma
make -C test -f Makefile.mem_itf
make -C test -f Makefile.arbiter
make -C test -f Makefile.data_ctrl
python3 -m unittest discover -s test -p test_compact_sram.py
make -f test/Makefile.psram_network build fixtures
python3 scripts/run_psram_network.py --profile
python3 scripts/summarize_optimization_stages.py
```

Synthesis was invoked explicitly per stage using `ACC_RTL_SNAPSHOT` and a fresh `ACC_MANUAL_OUT` with `scripts/measure_stream_area.tcl`. Normal tests and report scripts do not launch synthesis. Stage snapshots and `comparison.json` retain exact evidence. `register_timing.rpt` comes from a read-only DDC inspection, not another compile.
