# UART inputs and PSRAM programs / weights

Current physical macro: buffered 1 KiB SRAM, configured on the right; see
[sram_right_placement.md](sram_right_placement.md) for geometry and validation limits.

This stage retains MICRO, DMA, FP8 operation order and the existing 1 KiB SRAM.
The new program frontend replaces UART-fed instruction FIFO operation. The chip
uses only board-prepared PSRAM A; Flash and PSRAM B remain deselected.

## Board ownership and boot contract

The MCU owns the Pmod bus before execution. While the accelerator is deselected
or held in reset, the MCU initializes PSRAM, copies program/weights/data from
Flash, verifies them, and enters PSRAM QPI mode. It then releases its shared
GPIOs before selecting/releasing the accelerator. PSRAM must use linear burst
mode, not 32-byte wrapped mode, for arbitrary source addresses. The core tri-states all shared
outputs during reset; the top wrapper also gates output enables with `ena`.
Have the UART receiver listening before releasing reset so the first READY is
not lost. Deassert `ena` only when inactive, not in the middle of a transaction.

Boot firmware is board-version dependent and is not implemented by the RTL.
Tests initialize only the external PSRAM model to represent completed MCU
provisioning; SRAM inputs arrive over actual UART pins, and initial states arrive
through DMA. There is no simultaneous MCU/ASIC ownership during execution.

## UART protocol

8N1, low byte first for each 16-bit word. The chip sends one `01` READY credit per
word it can accept. The sender must consume that credit before sending a word.
There is no input FIFO: the MCU buffers incoming sensor data while the chip runs.
Credits pause during SRAM writes and program execution. The credit following the
final input word is emitted only after the program and outstanding units drain.
Do not send a speculative next input while the previous program is running.

| Word | Following words / action |
|---|---|
| `F100` CONFIG | program base low 16 bits; base high 8 bits (upper byte zero); instruction count; SRAM input base; input byte count |
| `F200` INPUT/RUN | exactly ceil(input byte count / 2) payload words, then automatic execution |
| `F300` RUN | execute the configured program without writing a new input |

CONFIG requires an even program base and 1..65535 instructions. The entire
program must fit in PSRAM A (0..0x7fffff). Input base must be even in 0..1022;
input byte count is 0..1024, and the complete input plus an optional padding byte
must fit in the 1 KiB SRAM. INPUT/RUN requires a nonzero configured input size.
An odd last input byte is padded with zero, not with the supplied high UART byte.
Programs replay from the configured start address; SRAM state persists across
frames. Programs must restore consumed MICRO configuration and pointers as needed.
The program region is read-only during execution; self-modifying code and external
MCU writes during chip ownership are outside this interface contract.

Unknown commands, invalid configurations, unexpected complete UART words during
execution, UART stop-bit errors, and core memory/sequence faults latch the error
output and stop further host acceptance until reset. The protocol has no CRC,
sequence/retry layer or receive timeout; a truncated input remains pending until
completed or reset. A UART bit error with valid framing is not detected by CRC.

UART default remains 87 core clocks/bit: about 115200 baud at 10 MHz, 574713 baud
at 50 MHz. Host software must match the chosen clock/divider.

## Program and memory execution

Existing 16-bit execution instructions retain their encoding. Logical external
MEM device `00` now means PSRAM A; `01` means internal SRAM; `10/11` are invalid.
PSRAM vector reads/writes are two bytes, may be unaligned, and must start at or
below `0x7ffffe`. DMA checks its complete source/destination spans before starting, then copies
1..4 vectors per chunk, bounded by the destination SRAM row.
Post-increment remains two bytes and preserves its existing saturation behavior.

The program frontend has one 64-bit instruction buffer, fetching at most four
instructions per request. The final request fetches only the remaining 1..3
instructions. There are no program branches, loops, instruction tags, or second
prefetch buffer. MICRO implements its generic column/batch loops and sparse
handling. The software-unrolling experiment was rolled back; opcode 101 is MICRO.

A two-owner arbiter serializes instruction fetch and data transactions. Data has
priority when both request an idle bus. Once accepted, the owner remains selected
until completion. Read bytes and completion are delivered exclusively to that
owner. While another owner is active, the pending request waits. Independent
SRAM/EXEC operations may still proceed where the existing hazard rules permit;
programs retain their required SYNC instructions.

For area, the QPI controller borrows the selected owner's stable address and
write-data registers until completion. Read bytes go directly into either the
existing 16-bit memory result or the frontend's 64-bit instruction buffer. There
is no extra 64-bit QPI receive buffer or weight cache. The frontend reuses its
program pointer/count while receiving input, and uses the UART receiver's held
word for the immediate SRAM write.

## Bounded PSRAM transactions

PSRAM uses QPI `0B` reads with four dummy SCK cycles and QPI `02` writes. SCK is
clk/2. Commands read 2..8 bytes per transaction; data reads/writes transfer two
bytes for ordinary MEM operations. DMA reads 2/4/6/8 bytes and fills the existing
64-bit SRAM row buffer before committing. Partial rows preload the old contents;
full rows overwrite without a read. DMA completion is after SRAM commit, not QPI
completion. There is no new payload cache. The bus remains released between
chunks; no Flash programming operations are used.

No transaction pauses with CS low. An eight-byte read holds CS low for 57 core
cycles (1.14 us at 50 MHz; 5.7 us at 10 MHz). These values fit the APS6404L standard
grade 8 us tCEM limit; the extended grade 3 us limit requires a faster core clock
(use at least 20 MHz for this controller). QPI 0B's 66 MHz SCK limit also applies;
this is not a claim that the synthesized logic or board meets those frequencies.
See the [AP Memory datasheet](https://www.apmemory.com/wp-content/uploads/APM_PSRAM_E3_QSPI-APS6404L-3SQR-v2.4-KGD_PKG.pdf).
No Flash program/erase/status operations exist in this build.

## Results

Programs can store results in PSRAM through ordinary MEM writes. UART TX still
sends READY credits, not numerical result packets. A future output protocol can
be added independently. The [MICRO reduction evaluation](micro_reduction.md) is a historical, rolled-back
experiment. See [area tradeoffs](area_tradeoffs.md) for possible future changes.

## Reproduce

```sh
# UART protocol, replay, batch 1/3/4, hazards, bounds and reset
make -C test
# MICRO batching, sparse control and backpressure
make -C test -f Makefile.micro
# Randomized ownership/backpressure
make -C test -f Makefile.arbiter
# Full Bishop EGRU+FC, using existing converted data/reference traces
make -f test/Makefile.psram_network
```

`prepare_psram_network.py` builds a board-preloaded PSRAM image with the program
at 0x300000 (below the raw-input queue reserved at 0x400000). Its input DMA is omitted: the input is supplied only through UART.
`psram_stream_host.py` is the corresponding host sender (pyserial for its CLI).
Tests are functional RTL simulation, not hardware or physical timing signoff.

## Current compact SRAM commands and staged measurements

Canonical `FFFF` remains SYNC. Stored opcode-111 encodings `E000..F7FF` now provide
compact SRAM operations; noncanonical legacy SYNC aliases in that range are no
longer barriers. `[12:9]` is the subcode and `[8:0]` is a two-byte SRAM vector
address. Subcodes: 0 input vector, 1 weight vector; 2/3 dense input scalar lane
0/1, 4/5 sparse input scalar lane 0/1; 6/7 dense weight scalar lane 0/1, 8/9 sparse
weight scalar lane 0/1; 10 result overwrite store, 11 result accumulate store.
Subcodes 12..15 retain barrier behavior. Dependencies still require SYNC before
EXEC consumes a pending operand and before a store consumes a new result.

MICRO uses compact weight/store operations only on its auto-DMA + SRAM-input
path. Other modes retain the ordinary command path. Generic batches, shapes,
external inputs and sparse behavior remain available. `compact_sram.py` folds
safe ordinary SRAM setup sequences in stored programs, retaining fences and
phase tags and refusing unknown/misaligned/out-of-range addresses.

See [staged area/performance results](optimization_stages.md). Historical
bottleneck and unrolling reports describe their saved revisions, not this RTL.
The linear/wrapped burst distinction is specified in the
[AP Memory APS6404L datasheet](https://www.apmemory.com/wp-content/uploads/APM_PSRAM_QSPI-APS6404L-3SQR-v2.3-PKG.pdf).
