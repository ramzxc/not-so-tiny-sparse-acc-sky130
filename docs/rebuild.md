# FP8 / 1 KiB rebuild

The current not-so-tiny RTL uses **FP8 E4M3FN**, two architectural lanes sharing
one multiplier and one arithmetic adder, and the existing
`tt_sram_1rw_64x128_sky130` OpenRAM macro. The physical word is 64 data bits plus
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

UART remains 8N1, receiving the low byte then the high byte of each **16-bit
instruction**. READY credits, the depth-two FIFO, pin assignments, QSPI headers
and byte transactions are unchanged. The default UART divider remains 87.

| Opcode | Operation |
| --- | --- |
| 000 | NOP |
| 001 | ADDR: low/high 12-bit fragment of a 24-bit byte address |
| 010 | MEM: Flash/SRAM, read/write, optional SRAM accumulate and post-increment |
| 011 | EXEC: ADD/SUB/MUL, overwrite/accumulate, activation |
| 100 | DATA: operand load selection or held-result store |
| 101 | MICRO: generic column-wise loop configuration and RUN |
| 110 | DMA: blocking Flash-to-SRAM copy |
| 111 | SYNC: wait for execution and memory completion |

MEM device 00 is Flash and 01 is SRAM. Devices 10/11 remain invalid. SRAM vector
bases must be even, in **0..1022**. Address 1023 cannot start a two-byte vector.
Flash vector bases may be unaligned but must not exceed `0xfffffe`. Rejected
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
with explicit source/destination setup. The complete Flash/SRAM span is checked
before the first access. Destination must be even and the end must be <=1024.

Each nonempty RUN uses one Flash read burst. CS remains asserted across bytes
and intermediate SRAM commits; SCK pauses low while the SRAM write completes.
The final byte closes the burst. This reuses the held 16-bit memory result,
without a second data FIFO. Host dispatch remains blocked until the final write
commits. Ordinary MEM Flash reads remain single-byte transactions.

## MICRO, including batching and automatic DMA

The existing generic loop and modes remain available; no EGRU dimensions or
state buffers are hardcoded. GROUPS and COLUMNS are 8-bit counts, up to 255.
BATCH is 1..128, subject to complete SRAM span validation.

| Command | Meaning |
| --- | --- |
| `0xa000 / 0xa001` | Capture input ADDR, Flash / SRAM |
| `0xa400 / 0xa401` | Capture weight ADDR, Flash / SRAM |
| `0xa800` | Capture SRAM output/partial-sum base |
| `0xac00 | G` | Number of two-lane output groups |
| `0xb000 | C` | Input column count |
| `0xb800 | B` | Batch size |
| `0xbc00` | Capture SRAM weight-buffer base |
| `0xbc01` | Capture Flash column stride in bytes; 0 means `2*G` |
| `0xb400 / 0xb401` | Ordinary dense / sparse RUN |
| `0xb402 / 0xb403` | Automatic-DMA dense / sparse RUN |

For column c, output group g and sample b:

```
packed input pair: input_base + 2*((c//2)*B + b)
Flash weight:     weight_base + c*stride + 2*g
weight buffer:    buffer_base + 2*g
partial sum:      acc_base + 2*(g*B + b)
```

Odd column counts require one padded input element per sample. Auto DMA requires
Flash weights and disjoint input (when SRAM), weight-buffer and output spans.
Every span is checked before execution. For B>1, sparse mode scans a column for
its first nonzero sample; an all-zero column skips both DMA and accumulation.
Otherwise the weight column is loaded once and reused across samples. Per-sample
zero skips remain supported. Input/weight pointers and COLUMNS are consumed;
restore them before another run. Other configuration is retained.

Partial sums are initialized by software and retained across input-column tiles.
STRIDE supports output tiles without repacking a complete Flash matrix. Results
may be dense or sparse; no network-specific buffer placement is imposed.
In particular there is no mandatory `y_new` allocation. Software may reuse
`y_old` storage only after all consumers of each old value have read it. Finishing
output j alone does not establish that old input j has no remaining consumers.

Queued runs need no intermediate host fence: MICRO blocks later dispatch until
completion. At a host-visible boundary send SYNC, one NOP, and wait for the next
READY credit; keep that credit for the next instruction. `scripts/micro_schedule.py`
provides host word generation, including conservative address-high elision.
Do not remove core dependency SYNC instructions from ordinary MEM/EXEC programs.

## Faults and integration status

Errors remain sticky on `uo_out[1]`; reset clears control/error state without
clearing SRAM. Reset aborts a paused Flash read; already committed writes remain.
A fault drains any accepted memory transaction before returning host ownership.
Earlier output columns may have committed before a later runtime fault.

The 1 KiB macro's existing Verilog, Liberty, LEF and GDS are reused. Simulation,
local synthesis library selection and the submission macro references now select
64x128. No synthesis, placement/routing, DRC/LVS, area or timing closure was run
for the new core. Existing macro placement, PDN obstruction geometry, local PNR
NDM libraries and old gate-level artifacts must be revisited before physical
implementation; updating the macro binding alone does not validate that layout.
