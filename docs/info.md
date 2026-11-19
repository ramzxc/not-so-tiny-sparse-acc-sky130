## How it works

Not-So-Tiny Sparse Accelerator is an FP8 E4M3FN accelerator for Tiny Tapeout SKY130
8×2 tiles. It uses the tiny-sparse-acc rebuild structure: UART, instruction FIFO,
decoder, data control, execution unit, memory interface and QSPI controller.
DATA can select either prefetched input element and broadcast it to both lanes
for column-wise computation. Sparse mode tests that selected element.
Instructions are 16 bits. Two FP8 E4M3FN lanes share one arithmetic multiplier and
adder. ReLU, hard sigmoid, hard tanh, STEP, accumulation and sparse weight reads
are supported. Hard sigmoid clamps `x/4 + 0.5` to `[0,1]`; hard tanh clamps
`x` to `[-1,1]`. Products, accumulators and stored values are FP8 E4M3FN (RNE, finite saturation).

A small micro sequencer can run a fixed column-wise loop. It loads input pairs,
selects each element, reads weights and accumulates products into SRAM. Configure
the input count, number of output groups and batch size, then issue RUN and SYNC.
Batch size 1 keeps the original order. Larger batches reuse each weight vector
across samples and keep separate SRAM partial sums. Optional automatic DMA mode
copies each active Flash weight column into a configured SRAM buffer before
computing it. Sparse mode skips DMA when the entire batch column is zero.
Configurable column stride supports output tiles of larger matrices; this is a
generic matrix primitive, with activations and network scheduling left to the host.

The memory interface selects external Flash or internal 1 KiB SRAM. PSRAM is
not used. A small blocking DMA copies Flash blocks to SRAM without arithmetic.
Set source, destination and length, then wait for completion before RUN.

GitHub Actions uses Yosys and OpenROAD. The FP8/1 KiB physical implementation
has not been revalidated; existing placement and PDN dimensions need review. Only the 1 KiB SRAM uses prebuilt physical views. Local DC/ICC2 runs
are a separate comparison flow; their outputs do not replace the Actions RTL.

### Source files

| Path | Contents |
| --- | --- |
| `src/rtl/project.v` | Logical top (`acc_hard_macro`) and module connections |
| `src/rtl/core/` | Micro sequencer, FIFO, decoder, data control, FP8 E4M3FN execution and activation |
| `src/rtl/uart/` | UART receiver and READY transmitter |
| `src/rtl/defs/` | Instruction and width definitions |
| `src/rtl/mem_itf.sv` | Flash/SRAM selection and vector transfers |
| `src/rtl/shared_sram.sv` | OpenRAM macro connection |
| `src/rtl/qspi_ctrl.v` | Byte transfers to Flash |
| `src/sources.f` | RTL source list |
| `memory/openram/` | SRAM models and physical views |
| `macro/acc_hard_macro/` | Previous hardened core |

The existing post-route netlist is
[acc_hard_macro.v](../macro/acc_hard_macro/acc_hard_macro.v).
New local synthesis writes `syn/runs/<run>/acc_hard_macro_gate.v`.
See [the design notes](rebuild.md) for instruction and arithmetic details.

### Pins and clocks

| Pin | Current RTL signal |
| --- | --- |
| `ui_in[3]` | UART RX, idle high |
| `uo_out[0]` | Decoder ready |
| `uo_out[1]` | Sticky memory/sequencer error; clear with reset |
| `uo_out[4]` | UART TX: READY credits |
| `uio[0]` | Flash CS_N |
| `uio[1]`, `uio[2]`, `uio[4]`, `uio[5]` | QSPI DQ0, DQ1, DQ2, DQ3 |
| `uio[3]` | QSPI SCK |
| `uio[6]`, `uio[7]` | Unused PSRAM selects, held high after reset |

Other dedicated inputs are unused and other outputs are zero.
Use a continuous 10 MHz clock. UART uses 87 clocks per bit (about 115200 baud),
8 data bits, no parity and one stop bit. For each READY byte `0x01`, send one
16-bit instruction, low byte first. Do not send more than one instruction per
credit. The FIFO holds two instructions. QSPI SCK is half the system clock.

`rst_n=0` resets control state. SRAM and Flash contents are retained. An already
committed memory write cannot be undone. Restart the credit protocol after reset.
As in tiny, `ena` is unused inside the core.

### Memory

| MEM selector | Memory | Byte address range |
| --- | --- | --- |
| `00` | External Flash | 24 bits; vector base at most `0xfffffc` |
| `01` | Internal SRAM | `0..511`; vector bases `0,4,...,508` |
| `10`, `11` | Unsupported | Requests rejected |

Each vector contains two FP8 E4M3FN values (4 bytes), with lane 0 in the low 16 bits.
SRAM is one continuous space with no fixed input, weight or accumulator regions.
Two vectors share each physical 64-bit SRAM word. Writes preserve the other
vector. Initialize SRAM before reading it; reset does not clear its contents.
MEM bit 8 optionally advances the byte address by 4 after each vector; it does
not automatically repeat the transfer. With bit 8 clear the address stays fixed.
Invalid accesses set the memory error output; invalid reads return zero and
invalid writes are discarded. Addresses do not wrap into valid SRAM.

## How to test

Install Verilator 5.036 or later and `test/requirements.txt`, then run:

```sh
make -C test
python3 -m cocotb_tools.check_results test/results.xml
make -C test -f Makefile.exec
python3 -m cocotb_tools.check_results /tmp/acc-fp16-exec/results.xml
make -C test -f Makefile.mem_itf
python3 -m cocotb_tools.check_results /tmp/acc-mem-itf/results.xml
```

Tests cover FP8 E4M3FN execution, UART instructions, QSPI Flash pins, SRAM bounds,
neighbor preservation, accumulation, sparse reads and reset behavior.
The pin test uses a shorter UART divider; hardware uses 87 clocks per bit.
The previous physical macro cannot pass the new instruction protocol test.

## External hardware

Use a host that supplies UART instructions, reset and a continuous system clock,
and a Flash connected in the TinyQV QSPI Pmod pin order shown above.
The Flash must already be in SPI mode with QE enabled. Writes require erased,
writable locations. The controller sends WREN, byte program and status polling;
it does not erase Flash or initialize the board. There is no polling timeout.
Intermediate data can stay in internal SRAM. Flash is not a random-write RAM.
