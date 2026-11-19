## How it works

Current physical macro: buffered 1 KiB SRAM, configured on the right; see
[sram_right_placement.md](sram_right_placement.md) for geometry and validation limits.

Not-So-Tiny Sparse Accelerator targets Tiny Tapeout SKY130 8×2 tiles. Its two
FP8 E4M3FN architectural lanes share one multiplier and arithmetic adder. The
existing 1 KiB OpenRAM macro stores inputs, states and working tiles. ReLU,
hard sigmoid/tanh, STEP, FP8 accumulation and sparse weight reads are supported.

The MCU loads program and weights from Flash into PSRAM A before enabling the
chip. UART then supplies configuration and input payloads. The frontend fetches
up to four existing 16-bit instructions per PSRAM transaction and replays the
configured program for each input. It has no branch/loop engine or second cache.
MICRO retains its generic column/batch loops and sparse automatic DMA behavior.

Instruction fetch and data access share one bounded QPI controller through a
transaction-owner arbiter. DMA transfers up to one SRAM row at a time using
the existing row buffer; compact SRAM commands reduce setup traffic. PSRAM A is the only external memory visible to the
chip; Flash and PSRAM B are deselected. SRAM accesses and FP8 execution keep their
existing dependency/SYNC contract. See [PSRAM stream](psram_stream.md) for the
complete UART, boot and ownership contract, and [rebuild](rebuild.md) for the ISA.

### Source files

| Path | Contents |
|---|---|
| `src/rtl/project.v` | Core wiring and reset synchronization |
| `src/rtl/core/program_ctrl.v` | UART framing, input commit, sequential program fetch/replay |
| `src/rtl/psram_arbiter.v` | Exclusive fetch/data transaction ownership |
| `src/rtl/core/micro_ctrl.v` | Generic column/batch sequencer |
| `src/rtl/core/dma_ctrl.v` | PSRAM-to-SRAM vector copies |
| `src/rtl/core/data_ctrl.v` | Address, operand selection, sparse reads and store snapshots |
| `src/rtl/core/exec_unit.sv` | FP8 arithmetic and activations |
| `src/rtl/mem_itf.sv` | Ordinary vectors, row-bounded DMA and SRAM RMW |
| `src/rtl/qspi_ctrl.v` | PSRAM A QPI 0B/02 transfers |
| `src/rtl/shared_sram.sv` | Existing 64x128 OpenRAM macro |
| `src/rtl/uart/` | UART word receiver and READY transmitter |

### Pins and clocks

| Pin | Signal |
|---|---|
| `ui_in[3]` | UART RX |
| `uo_out[0]` | Frontend idle/configuring; not a UART credit |
| `uo_out[1]` | Sticky host/UART/memory/sequencer fault |
| `uo_out[4]` | UART TX: READY credits |
| `uio[0]` | Flash CS_N held high while active |
| `uio[1]`, `uio[2]`, `uio[4]`, `uio[5]` | QPI DQ0..DQ3 |
| `uio[3]` | QPI SCK, clk/2 |
| `uio[6]` | PSRAM A CS_N |
| `uio[7]` | PSRAM B CS_N held high while active |

UART uses 87 core clocks per bit by default (about 115200 baud at 10 MHz), 8N1,
low byte first. Each READY byte permits exactly one 16-bit host protocol word,
not an execution instruction. Reset tri-states shared outputs and clears control;
it does not clear SRAM/PSRAM. Wrapper `ena=0` gates shared output enables and must
only be used when execution is inactive. MCU pins must be released before the
ASIC drives the bus. See PSRAM tCEM/clock requirements in the interface document.

### Memory

| MEM selector | Memory | Legal two-byte vector bases |
|---|---|---|
| `00` | PSRAM A | `0..0x7ffffe` (unaligned supported) |
| `01` | Internal 1 KiB SRAM | even addresses `0..1022` |
| `10/11` | Reserved | rejected |

Lane 0 occupies the lowest byte. Four vectors share one 64-bit SRAM row; RMW
preserves neighboring vectors. Initialize SRAM before use; reset retains its
contents. MEM post-increment adds two bytes, saturating at the 24-bit address
limit. Invalid spans fault without truncation/wrap or partial writes.

### Test

```sh
make -C test
python3 -m cocotb_tools.check_results test/results.xml
make -C test -f Makefile.arbiter
make -C test -f Makefile.exec
make -C test -f Makefile.mem_itf
```

The default suite covers UART inputs, replay, batch 1/3/4, both arbitration wait
directions, final/unaligned PSRAM addresses, invalid configurations, framing
faults and reset. Full Bishop tests use `make -f test/Makefile.psram_network` after
preparing the FP8 reference traces. UART result payload transmission is not part
of this stage; programs can store numerical results in PSRAM.

Only the SRAM has validated physical macro views. Historical full-chip netlists,
placement/PDN geometry and timing are not signoff evidence for this RTL revision.
Local synthesis comparisons do not replace a complete physical implementation.

Current staged measurements: [area and performance](optimization_stages.md).
