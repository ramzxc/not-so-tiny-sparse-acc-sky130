# FP8 / 1 KiB rebuild

The current not-so-tiny RTL uses **FP8 E4M3FN**, two architectural lanes sharing
one multiplier and one arithmetic adder, and the existing
`tt_sram_1rw_64x128_buffered_sky130` OpenRAM macro. The physical word is 64 data bits plus
one unused spare bit; 128 rows provide 1,024 data bytes. Arithmetic functions
are reused from `tiny-sparse-acc-gf180/src/rtl/defs/fp8_math.vh`.

The preceding FP16/512 B specification is retained in
[rebuild_fp16_512.md](rebuild_fp16_512.md). Previous performance/area reports and
hardened netlists are historical and are not evidence for this RTL revision.

## Numeric and vector contract

- FP8 E4M3FN: one sign bit, four exponent bits, three fraction bits, bias 7.
- Round to nearest, ties to even. Finite overflow saturates to +/-448.
- Canonical NaN is `0x7f`; signed zeros and subnormals are supported.
- Inputs, weights, products, accumulators and stored outputs are all FP8.
  MUL rounds the product before optional accumulation; it is not a fused MAC.
- One vector is **two bytes**, lane 0 at the lower address. There are four
  independently writable vectors per 64-bit SRAM row. RMW preserves the other
  three vectors. The two FP8 accumulation lanes share one SRAM-side adder.
- Hard sigmoid is clamp(round8(round8(x/4)+0.5),0,1); hard tanh is clamp(x,-1,1).
  ReLU, STEP and NONE retain their existing instruction encodings.
- Sparse scalar mode skips zero terms, including either sign of zero. Dense
  mode retains normal NaN propagation. A zero skip preserves partial sums.

This is a numeric-format change, not a bit-equivalent replacement for FP16.
Convert the model/input binaries to E4M3FN before execution. No task-accuracy,
full-network throughput or physical timing claim accompanies this conversion.

## Interfaces and commands

The current boot/UART protocol is specified in [PSRAM stream](psram_stream.md).
The MCU preloads PSRAM A; UART carries configuration and input payloads.


The stored program uses the 16-bit instructions below; compact SRAM operations
extend opcode 111 as documented in [PSRAM stream](psram_stream.md). UART no longer
feeds these instructions directly; the program frontend fetches up to four
instructions per PSRAM read. READY credits now apply to host protocol words.

| Opcode | Operation |
| --- | --- |
| 000 | NOP |
| 001 | ADDR: low/high 12-bit fragment of a 24-bit byte address |
| 010 | MEM: PSRAM/SRAM, read/write, optional SRAM accumulate and post-increment |
| 011 | EXEC: ADD/SUB/MUL, overwrite/accumulate, activation |
| 100 | DATA: operand load selection or held-result store |
| 101 | MICRO: generic column-wise loop configuration and RUN |
| 110 | DMA: blocking PSRAM-to-SRAM copy |
| 111 | Compact SRAM subcodes 0..11; subcodes 12..15 remain SYNC (`FFFF` canonical) |

MEM device 00 is PSRAM and 01 is SRAM. Devices 10/11 remain invalid. SRAM vector
bases must be even, in **0..1022**. Address 1023 cannot start a two-byte vector.
PSRAM vector bases may be unaligned but must not exceed `0x7ffffe`. Rejected
requests do not wrap or partially update memory. Post-increment advances by
**2 bytes** after completion, saturating at `0xffffff` on 24-bit overflow.

DATA LOAD can select either prefetched FP8 element and broadcast it to both
lanes. EXEC snapshots operands/mode, so changes while busy cannot affect the
accepted operation. Results remain held until replaced. Ordinary dependent
MEM/EXEC sequences still require SYNC before consuming an unfinished operand
or result. See `src/rtl/defs/inst_defs.vh` for exact encodings.

## DMA

SOURCE (`0xc000`) and DEST (`0xc400`) capture ADDR. RUN (`0xc800 | count`)
transfers **count two-byte vectors**, with count 0..255; zero is a no-op.
A single RUN copies at most 510 bytes. Larger copies require consecutive RUNs
with explicit source/destination setup. The complete PSRAM/SRAM span is checked
before the first access. Destination must be even and the end must be <=1024.

Each RUN copies row-bounded chunks of 1..4 vectors through QPI. The existing
SRAM row buffer preserves partial-row neighbors and commits once per chunk,
avoiding a separate weight cache and never pausing CS low for SRAM. Host dispatch remains blocked until the
final write commits. Instruction fetch requests arbitrate with these data reads.

## MICRO, including batching and automatic DMA

MICRO remains in the active hardware. Generic GROUPS and COLUMNS are 8-bit counts,
up to 255; BATCH is 1..128, subject to complete SRAM span validation. No EGRU
shape, gates or state buffers are hardcoded. The software-unrolling experiment
was rolled back because of its instruction-fetch cost.

| Command | Meaning |
| --- | --- |
| `0xa000 / 0xa001` | Capture input ADDR, PSRAM / SRAM |
| `0xa400 / 0xa401` | Capture weight ADDR, PSRAM / SRAM |
| `0xa800` | Capture SRAM output/partial-sum base |
| `0xac00 | G` | Number of two-lane output groups |
| `0xb000 | C` | Input column count |
| `0xb800 | B` | Batch size |
| `0xbc00` | Capture SRAM weight-buffer base |
| `0xbc01` | Capture PSRAM column stride; 0 means `2*G` |
| `0xb400 / 0xb401` | Ordinary dense / sparse RUN |
| `0xb402 / 0xb403` | Automatic-DMA dense / sparse RUN |

For column c, output group g and sample b:

```
packed input pair: input_base + 2*((c//2)*B + b)
PSRAM weight:     weight_base + c*stride + 2*g
weight buffer:    buffer_base + 2*g
partial sum:      acc_base + 2*(g*B + b)
```

Odd column counts require a padded element per sample. Automatic DMA requires
PSRAM weights and disjoint input (when SRAM), weight-buffer and output spans.
For B>1, sparse mode scans for the first nonzero sample: an all-zero column
skips both DMA and accumulation. Otherwise the column is loaded once and reused
across samples, retaining per-sample zero skips. Input/weight pointers and COLUMNS
are consumed; restore them for another run. Other configuration is retained.

Software initializes partial sums; STRIDE allows output tiling without repacking
whole matrices. No network-specific buffer placement is imposed. Software may
reuse `y_old` only after all consumers of each old element finish reading it.
Ordinary MEM/EXEC sequences retain their required SYNCs. MICRO blocks following
dispatch until completion; UART host READY follows the complete stored program.
`scripts/micro_schedule.py` generates MICRO IR words with conservative address-high
elision; place these words in PSRAM, not directly in the UART input protocol.

## Faults and integration status

Errors remain sticky on `uo_out[1]`; reset clears control/error state without
clearing SRAM. Reset aborts an active PSRAM transaction; already committed writes remain.
A fault drains any accepted memory transaction before returning host ownership.
Earlier output columns may have committed before a later runtime fault.

The current binding uses the buffered 1 KiB macro imported on 2026-11-19.
Verilog, Liberty, LEF, GDS and LVS SPICE now select that same macro. Right-side
placement and side-entry power feeds are configured; see
[sram_right_placement.md](sram_right_placement.md). The buffered NDM must be
built before a fresh ICC2 run. Previous synthesis and routed artifacts remain
historical; this integration has not undergone placement/routing or integrated
PDN DRC/connectivity checks. The imported Liberty uses analytical timing.

Current complete-network software SRAM layout and measurements: [aligned weight scratch](weight_alignment.md).
