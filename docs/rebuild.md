# FP16 adaptation of tiny

The baseline is `tiny-sparse-acc-gf180` at commit
`d560bedfde974775d1b444fecdced82c80a86d05`. Source hashes are recorded in
[rebuild_import.json](rebuild_import.json).

```text
project.v (acc_hard_macro)
  UART RX -> inst_fifo -> micro_ctrl -> dma_ctrl -> inst_decoder -> exec_unit
                                                              -> data_ctrl
                                         DMA / data_ctrl -> mem_itf -> QSPI -> Flash
                                                                   -> shared_sram
  UART TX <- FIFO READY
```

The hierarchy and 16-bit instruction format follow tiny. The changes needed
here are FP16 arithmetic, two lanes sharing arithmetic hardware, and a 512 B
OpenRAM SRAM behind the memory interface. UART and QSPI transfers remain 8 bits.
There is no separate SPI host bridge or old DMA/controller path.

## Instructions

| Opcode `[15:13]` | Fields |
| --- | --- |
| `000` NOP | No operation |
| `001` ADDR | Bit 12 selects low/high 12 address bits |
| `010` MEM | Bit 12 write, bits 11:10 device, bit 9 SRAM accumulation, bit 8 post-increment |
| `011` EXEC | Bit 12 accumulate, bits 11:10 operation, bits 9:7 activation |
| `100` DATA | Bit 12 store, bit 11 sparse, bit 10 weight/input, bit 9 input selector, bit 8 scalar mode |
| `101` MICRO | Configuration and fixed column-wise RUN |
| `110` DMA | Blocking Flash-to-SRAM copy |
| `111` SYNC | Wait for data control and execution |

MEM device `00` retains tiny's Flash path. Previously unused device `01` selects
flat SRAM. Devices `10/11` are rejected. MEM bit 9 is a local extension for
SRAM read-add-write; it is valid only on SRAM writes. Other reserved bits should
be zero. Instruction macros are in `src/legacy/defs/inst_defs.vh`.

DATA LOAD selects the operand register for the following MEM READ. DATA STORE
snapshots the last held execution result; MEM WRITE stores that snapshot.
Use SYNC after loads and execution before consuming their results. MEM bit 8 enables address post-increment by 4 bytes after each completed
vector, including sparse-skipped reads and rejected requests. With bit 8 clear,
the address stays unchanged. It does not repeat the operation: issue another MEM
for the next vector. Reads, writes and SRAM accumulation all support this option.
The address remains stable during stalls. SRAM address 508 advances to 512,
where the next SRAM access is rejected. A 24-bit overflow saturates at `0xffffff`
(an invalid vector base), never wraps to zero. ADDR can explicitly set a new
address; reset clears it. `INST_MEM_POSTINC(inst)` enables the option on a MEM
preset. SRAM vectors use 4-byte-aligned
byte addresses from 0 through 508. Flash vectors serialize into four bytes,
low byte first, and must not cross the 24-bit address limit.

## Arithmetic and sparsity

Operations are ADD (`00`), SUB (`01`) and MUL (`10`). MUL accumulation adds the
rounded FP16 product to the raw accumulator. ADD and SUB overwrite it.
Two lanes run sequentially through one arithmetic multiplier and one adder.
Activation runs after the raw result is saved. The output remains held until
the next completed execution. Operands are captured when EXEC starts.

Activation codes are none (`000`), ReLU (`001`), tanh (`010`), sigmoid (`011`)
and STEP (`100`). Activations follow tiny's hard formulas, evaluated in FP16:
`sigmoid(x) = clamp(round16(round16(x/4) + 0.5), 0, 1)` and
`tanh(x) = clamp(x, -1, 1)`. ReLU and STEP retain their standard sign tests.
All activation modes, including NONE and STEP, canonicalize NaN to `0x7e00`.
Activation is part of `exec_unit.sv`, controlled by its main FSM.
The two lanes share one sigmoid datapath and run one lane per cycle.
There is no separate activation module, operand latch, or ready/valid handshake.
EXEC preserves the raw accumulator and publishes both activated lanes together. The older
piecewise sigmoid and sigmoid-derived tanh are no longer used.
`defs/fp16_math.vh` supplies module-local numeric helpers and activation constants.
It is included inside each module, like tiny's FP8 math header. SystemVerilog
modules keep `.sv` extensions; plain Verilog modules use `.v`.

DATA LOAD bit 8 enables scalar broadcast, and bit 9 selects input element 0/1.
Both elements remain in the input register. Selection does not read memory,
consume an element, advance an address or change automatically after EXEC.
The selected FP16 value feeds both lanes; weights remain a two-element vector.
With bit 8 clear, the original element-wise vector behavior is retained.
Every DATA LOAD updates selection, scalar mode and sparse mode, including
weight-target commands. DATA STORE leaves these settings unchanged. Reset
selects element 0 and disables scalar and sparse modes.

In scalar mode, sparse weight reads test only the selected input. In vector
mode, both input elements must be zero to skip. Both signs of zero count as
zero; subnormals do not. A skipped read supplies zero weights to avoid stale
values. In scalar sparse mode, a zero-input MUL accumulation bypasses arithmetic
and leaves raw accumulators unchanged; MUL overwrite produces a zero vector.
The requested activation still runs on that raw result. ADD/SUB do not bypass
arithmetic. Sparsity assumes zero terms can be omitted even with non-finite
weights; use dense mode for normal FP16 zero-times-infinity/NaN behavior.

Selection, mode and operands are captured for each accepted EXEC; later DATA
commands cannot alter an operation already running. After changing the selected
column, load its corresponding weights before executing (unless intentionally
reusing them). A previous skipped read did not fetch the other column's weights.

Example: preload input `[x0,x1]` once, then for each column:

```text
DATA WEIGHT_SCALAR_SPARSE(cur=0)
ADDR weight_column_0
MEM READ; SYNC
EXEC MUL overwrite; SYNC
DATA WEIGHT_SCALAR_SPARSE(cur=1)
ADDR weight_column_1
MEM READ; SYNC
EXEC MUL accumulate; SYNC
DATA STORE
ADDR output
MEM WRITE
```

Use `INST_DATA_WEIGHT_SCALAR_SPARSE(1'b0)` / `(1'b1)` macros for selection.
For manual execution across several output groups, keep the same selector
while loading each group's weights and manage partial sums explicitly. The
execution unit has one two-element raw accumulator. The micro sequencer below
automates partial-sum updates in SRAM using the existing memory accumulator.
Input loads still transfer two FP16 elements (4 bytes), so MEM post-increment
remains +4 for input, weight and result transfers.

SRAM accumulation uses a separate shared FP16 adder in mem_itf, one lane at a
time. Its read-modify-write also preserves the other vector in the 64-bit word.
The SRAM is 64 bits × 64 rows, not a 32-bit-wide physical macro.

## Fixed micro sequencer

`core/micro_ctrl.v` sits between the instruction FIFO and decoder. It contains
an FSM, address registers and counters, not a CPU or instruction RAM. When idle,
ordinary instructions pass through. During RUN it owns dispatch, emits ordinary
DATA/ADDR/MEM/EXEC/SYNC commands, and backpressures queued host instructions.
A host SYNC after RUN waits for the entire loop. UART credits still apply.

With batch size 1 (the reset default), the existing sequence is unchanged:

```text
read two inputs when a new input pair is needed
select cur = 0 or 1
for each output group:
    read two weights
    EXEC MUL overwrite, no activation
    DATA STORE captures the product
    MEM SRAM accumulation reads partial sums, adds the product, and writes back
advance cur; after cur=1, load the next input pair
```

This reuses the existing MAC, SRAM FP16 adder and transfer buffers. There is no
new arithmetic unit, partial-sum buffer or microcode memory. A shared pointer
adder advances input or weight addresses. Sparse zero columns skip all weight
reads, arithmetic and output writes; weight addresses still advance over that
column. Both signs of zero skip; nonzero subnormals do not. Dense mode retains
FP16 NaN/infinity behavior.

### Configuration

MICRO opcode is `101`. Bits 12:10 choose the operation below. Reserved bits must
be zero. Address settings capture the current ordinary ADDR register, so send
ADDR LOW/HIGH first. Configuration waits until execution and data control are idle.

| Word / subcommand | Payload and meaning |
| --- | --- |
| `0xa000` INPUT | Bit 0: 0=Flash, 1=SRAM; capture input base address |
| `0xa400` WEIGHT | Bit 0: 0=Flash, 1=SRAM; capture weight base address |
| `0xa800` ACC | Capture SRAM output base, aligned to 4 bytes |
| `0xac00` GROUPS | Bits 7:0: number of two-output groups |
| `0xb000` COLUMNS | Bits 7:0: number of scalar inputs (columns), 0..255 |
| `0xb400` RUN | Bit 0: enable sparse skipping |
| `0xb800` BATCH | Bits 7:0: batch size, 1..128; reset default 1 |

Macros `INST_MICRO_INPUT`, `INST_MICRO_WEIGHT`, `INST_MICRO_ACC`,
`INST_MICRO_GROUPS`, `INST_MICRO_COLUMNS`, `INST_MICRO_BATCH` and `INST_MICRO_RUN` are provided in
`defs/inst_defs.vh`. Supply 1-bit flags and 8-bit counts to their arguments.

GROUPS is the output-loop length, not a byte count: 2 groups update 4 FP16
outputs. At base 0, SRAM holds at most 128 groups; a higher base reduces that
limit. COLUMNS is independent. Zero groups or zero columns is a no-op. RUN
starts with cur=0, advances it automatically, and consumes input/weight pointers
and the column counter in place to save registers. Reconfigure those values
before another independent run. GROUPS, BATCH and output base persist. Every input
load reads 4 bytes; pad the final pair if the scalar input count is odd.

Weights are column-major: within each column, groups occupy consecutive
4-byte vectors. Input pairs occupy consecutive 4-byte vectors. Outputs use the
same SRAM group addresses for every column. Initialize output partial sums
before RUN; nonzero initial values act as bias or previous partial sums.
Input/weight storage must not overlap output storage that RUN will modify.

Example: five inputs, four outputs, Flash inputs at `0x200`, Flash weights at
`0x300`, SRAM partial sums at byte 128:

```text
ADDR 0x200; MICRO INPUT(Flash)
ADDR 0x300; MICRO WEIGHT(Flash)
ADDR 128;   MICRO ACC
MICRO GROUPS(2)
MICRO COLUMNS(5)
MICRO RUN(sparse=1)
SYNC
```

RUN performs raw product accumulation, not activation. Apply activation after
all columns have been accumulated using ordinary instructions. Result registers
are scratch state after RUN; the accumulated results are in SRAM. In particular,
EXEC's held result is the last product, not the whole output vector. The input
buffer and DATA selection are also scratch state; restore the desired mode for
subsequent manual commands. DMA is configured separately. Arbitrary instruction loops and a general
activation-length engine are not part of MICRO.

### Batched weight reuse

Set `MICRO BATCH(B)` before RUN (`0xb804` for four samples). B=1 preserves the
original instruction sequence. For B>1 the sequence is:

```text
for each input column c:
    for each output group g:
        read weight[c][g] once into the existing weight register
        for each sample b:
            read input pair[c / 2][b], select cur = c % 2
            accumulate weight[c][g] * selected_input into partial[g][b]
```

Addresses are byte addresses. The packed layout is:

- Input pair: `input_base + 4 * ((c / 2) * B + b)` (integer division).
  Both FP16 elements of each sample's pair stay together. Pad the last pair.
- Weight vector: `weight_base + 4 * (c * GROUPS + g)`; unchanged by batch size.
- Output pair: `acc_base + 4 * (g * B + b)` in SRAM.

For example, B=2 packs input pairs as `[x0[0],x0[1]], [x1[0],x1[1]],
[x0[2],x0[3]], [x1[2],x1[3]], ...`. The host prepares this layout. There is no
hardware transpose or configurable stride. The formulas describe the layout;
RTL uses counters and additions, with no new multiplier or data buffer.

Each weight vector stays loaded for all B samples. Inputs are read again for
other output groups and columns; placing them in SRAM avoids repeated Flash
input reads. Sparse mode skips the product and output update for each zero
sample, including signed zero. Weight is read once even if all B samples are
zero. B=1 retains its original complete zero-column weight-read skip.

The output tile needs `4 * GROUPS * B` bytes and must fit from ACC base through
byte 511. RUN checks this using repeated addition before issuing memory work.
Input/weight data stored in SRAM also need separate space. Software chooses
smaller tiles, initializes or restores partial sums, issues RUN, and saves the
results before reusing that space. DMA is an explicit command, not an automatic action inside MICRO. Spilling and
Flash erase management remain software responsibilities.

BATCH counts already available input vectors. Independent samples or the input
projection of several known EGRU timesteps may share weights this way. Recurrent
hidden-state inputs must still be produced in dependency order; BATCH does not
remove that dependency. Activations remain explicit after all column tiles.

### Bounds, faults and reset

The entire output span is checked before RUN starts. Invalid configuration or
output span sets the sticky error on `uo_out[1]` without starting the loop.
Input/weight accesses use mem_itf's existing bounds checks on each vector. A
memory fault stops instruction issue, drains the accepted operation and returns
host ownership with the error set. Earlier completed output updates remain;
RUN is not transactional. Address overflow saturates to an invalid vector base
instead of wrapping to low memory. Sparse-skipped weight ranges are not read.
Reset clears configuration, busy and error; it does not clear SRAM or roll back
writes already committed. Clear errors with reset before another RUN.

## Flash-to-SRAM DMA

`core/dma_ctrl.v` copies raw bits using the existing memory interface and QSPI
controller. It blocks instruction dispatch until the final SRAM write has
committed. It does not overlap transfers with computation. A following SYNC
waits for completion; UART READY credits only report FIFO capacity, not DMA DONE.
Errors use the existing sticky error output (`uo_out[1]`).

| Word | Meaning |
| --- | --- |
| `0xc000` SOURCE | Capture current ADDR as a 24-bit Flash source |
| `0xc400` DEST | Capture current ADDR as an aligned SRAM destination, 0..508 |
| `0xc800 + count` RUN | Copy count 4-byte vectors, 0..128; zero is a no-op |

Bits 9:8 of RUN and all payload bits of SOURCE/DEST must be zero. Other DMA
subcommands are invalid. Macros `INST_DMA_SOURCE`, `INST_DMA_DEST`, and
`INST_DMA_RUN(8'd32)` are in `defs/inst_defs.vh`.

Example: copy 128 bytes from Flash 0x1000 to SRAM 0:

```text
ADDR 0x1000; DMA SOURCE
ADDR 0;      DMA DEST
DMA RUN(32)
SYNC
```

The example takes seven instruction words before SYNC: two ADDR words and one
capture command per address, then RUN. SOURCE may be unaligned; DEST must be
4-byte aligned. Both complete ranges are validated before any transfer. Neither
range may wrap, and the destination must end at or below byte 512. An invalid
copy issues no memory access. Reset clears the sticky error before another RUN.

The transfer reads four Flash bytes and writes one SRAM vector, preserving the
other 32-bit half of the SRAM row. It reuses mem_itf's held read_data register,
so no second data buffer is added. NaN payloads, subnormals and signed zeros are
copied unchanged. DMA does not load execution operands, change DATA mode,
modify the ordinary ADDR register, or update the held arithmetic result.

Source and destination advance between vectors and finish on the final copied
vector. Reconfigure both addresses before another independent copy. On a fault,
DMA stops issuing requests and drains the accepted operation. Already committed
writes remain. Reset cancels control state without clearing SRAM.

Input and weight tiles may both be copied. After a copy, configure MICRO INPUT
or WEIGHT for SRAM and use the packed layout described above. Output partial
sums must occupy a separate range. The copy is contiguous: it does not transpose
inputs, change strides, or automatically tile a larger model. This DMA supports
Flash-to-SRAM only; it does not add Flash programming or erase management.

## Reset and physical builds

Reset clears control and error state, not memory. A pending operation may be
cancelled before its write is captured by the SRAM; a captured write can still
commit. External Flash operations already started cannot be undone.

`src/legacy/sources.f` lists the historical rebuild RTL. Existing macro GDS, LEF, netlist and timing
views are from the previous core. They are not inputs to the current Actions flow. Actions synthesizes the RTL
and uses only the SRAM physical macro. Local DC/ICC2 builds remain separate.
