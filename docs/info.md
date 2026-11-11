## How it works

Two-lane FP16 sparse accelerator imported from `/docker/projects/egru/acc/rtl`
(with `lib/tpu_pkg.sv`). The original directory is preserved. The imported
weight-cache version has been changed to a software-managed `weight_buffer`:
`OPCODE_DRAM_TO_WEIGHT` (0x41) explicitly loads rows through DMA; a WEIGHT
instruction then reads a local WB row, with no tags, replacement, or demand refill.
The cache and replacement-policy files are retained for reference but excluded
from both source manifests and the instantiated hierarchy.

WB, UB and ACC now share one generated OpenRAM 64-bit 1RW macro through
`mem_ctrl`. The compute width remains two FP16 lanes. Logical addresses are
32-bit row indices within each region; even/odd rows occupy the low/high half
of one physical word. The instruction format and 64-bit AXI interface are unchanged.

| Capacity | UB | ACC | WB | Physical words |
|---|---|---|---|---|
| 1 KiB | 512 B / 128 rows | 256 B / 64 rows | 256 B / 64 rows | 128 x 64 bits |
| 512 B | 256 B / 64 rows | 128 B / 32 rows | 128 B / 32 rows | 64 x 64 bits |

Physical word bases are UB=0, ACC=64, WB=96 for 1 KiB and UB=0, ACC=32,
WB=48 for 512 B. These physical bases are hidden from software. Programs whose
logical addresses fit the smaller partitions run unchanged on both sizes.

Instruction, DMA, VPU metadata and activation metadata FIFO depths are all 4.
DMA uses a data-only row FIFO and sequential local addresses. External DMA
addresses must be 8-byte aligned; odd row counts use partial final beats.
The controller round-robins twelve request channels. Read responses are registered on the clock edge after request acceptance. Each client has a response holding slot;
backpressure on one client does not block the other clients. A write reads a
physical word, optionally adds the two FP16 accumulator operands, and commits
an updated word while preserving the other 32-bit row. This transaction occupies
three clock edges and cannot interleave with another access. The macro has no
byte write mask. VPU results are held until accepted; at most one VPU computation
is in flight, so the old fully pipelined throughput is not retained.

Instruction dependency checks and SYNC include pending memory operations.
Memory contents are not reset. Reset cancels uncommitted controller requests;
it does not undo writes already captured by the macro. Out-of-range requests
never wrap into another region: reads return zero, writes are discarded, and
status bit 6 latches an error until reset. Software must regard that transfer as
failed and check bounds before submitting a multi-row command (earlier valid
rows in an out-of-range burst may already have committed).

Select `ACC_SRAM_BYTES=512` or `1024` at compile time; the default is 512.
Simulation uses `make -C test SRAM_BYTES=512` / `1024`. DC uses the environment
variable with the same name. P&R uses `src/config_512.json` / `config_1024.json`,
which select the matching define and GDS/LEF/Liberty/blackbox. `config.json` is the
512 B default. No RTL edit or request-interface change is needed to switch.

The generated macros pass macro-level DRC/LVS, but their TT Liberty timing is
an analytical estimate, not SPICE characterization. Full-chip placement,
routing, PDN and timing signoff are not done. See `memory/openram/README.md`.

The top module is `tt_um_not_so_tiny_sparse_acc_ramzxc`. `rst_n=0` resets the
interface and accelerator. `ena=0` also holds them in reset; deselection discards
in-flight work. The system clock target is 10 MHz (`CLOCK_PERIOD=100` ns).
`SLANG_ARGUMENTS` raises the bounded loop-unroll limit to 16384 for the nested
FP16 activation functions. `USE_SLANG` enables package/packed-type support in the LibreLane synthesis flow;
see the [LibreLane configuration reference](https://librelane.readthedocs.io/en/latest/reference/step_config_vars.html).

## How to test

Install Verilator 5.036 or newer (tested with 5.052) and the Python packages in `test/requirements.txt`, then run:

```sh
cd test
make
python -m cocotb_tools.check_results results.xml
```

The default RTL simulator is Verilator because the source uses SystemVerilog
packages, packed structures, and casts. Gate-netlist simulation can use
`make GATES=yes SIM=icarus`. The pin-level test checks SPI ID, reset, aborted
transactions, synchronization, a two-beat DMA round trip with backpressure,
FP16 vector addition and accumulator readout, explicit two-row WB preloading,
WB-based scalar multiplication, error reporting, and deselection.
The imported core has width-conversion lint warnings; these are nonfatal in the
simulation Makefile. The simulation is not a complete accelerator ISA regression.

### Pins and SPI timing

| Pin | Signal |
| --- | --- |
| `ui_in[0]` | SPI SCK |
| `ui_in[1]` | SPI CS_N, idle high |
| `ui_in[2]` | SPI MOSI |
| `uio[0]` | SPI MISO, output enabled only while selected and out of reset |
| `uo_out[7:0]` | Status, same as read register 0 |
| Remaining pins | Unused; all other bidirectional pins are inputs |

Use SPI mode 0 (CPOL=0, CPHA=0), MSB first. SCK and CS are synchronized to `clk`.
Keep each SCK half-period at least four system-clock cycles; SCK must not exceed
`clk/8` (1.25 MHz at 10 MHz). Keep CS low for at least four system-clock cycles
before the first rising SCK edge and after the final rising edge. Keep CS high
for at least four system-clock cycles between transactions. Provide a running
system clock throughout communication and computation.

Every transaction is exactly two bytes under one CS assertion:

| Command byte | Second byte | Meaning |
| --- | --- | --- |
| `0x00 | address` | Dummy byte; read result appears on MISO | Read register |
| `0x40 | address` | Data | Write staging register |
| `0x80` | Action mask | Perform actions |

Addresses are six bits. Read and write maps are distinct. No auto-increment or
burst SPI transfer is supported; extra bytes are ignored until CS rises. Partial
transactions are discarded. Reserved commands and writes are ignored; reserved
reads return zero. Read data is latched after the command byte. Multibyte values
are little-endian by register address.

### Write registers

| Address | Value |
| --- | --- |
| 0–7 | 64-bit instruction staging, least-significant byte first |
| 8–15 | 64-bit AXI RDATA staging, least-significant byte first |
| 16 | R metadata: `[6]=RLAST`, `[5:4]=RRESP`, `[3:0]=RID` |
| 17 | B metadata: `[5:4]=BRESP`, `[3:0]=BID` |

Staging writes do not submit anything. R and B submission copies the staged
payload into independent pending registers, held stable until the TPU accepts
it. Check the pending bits before submitting another response.

### Read registers

| Address | Value |
| --- | --- |
| 0 | `[7]=host_error`, `[6]=axi_error OR memory bounds error`, `[5]=sync_seen`, `[4]=FIFO full`, `[3]=FIFO empty`, `[2]=ARVALID`, `[1]=WVALID`, `[0]=AWVALID` |
| 1 | `[3]=BREADY`, `[2]=RREADY`, `[1]=B pending`, `[0]=R pending` |
| 2–5 | AWADDR, little-endian |
| 6 | AWLEN (beats minus one) |
| 7 | `[7:4]=AWID`, `[2:0]=AWSIZE` |
| 8 | AWBURST |
| 9–12 | ARADDR, little-endian |
| 13 | ARLEN (beats minus one) |
| 14 | `[7:4]=ARID`, `[2:0]=ARSIZE` |
| 15 | ARBURST |
| 16–23 | WDATA, little-endian |
| 24 | WSTRB |
| 25 | `[0]=WLAST` |
| 26 | `[7:4]=AWCACHE`, `[3:1]=AWPROT`, `[0]=AWLOCK` |
| 27 | `[7:4]=AWREGION`, `[3:0]=AWQOS` |
| 28 | `[7:4]=ARCACHE`, `[3:1]=ARPROT`, `[0]=ARLOCK` |
| 29 | `[7:4]=ARREGION`, `[3:0]=ARQOS` |
| 30–31 | Shared SRAM capacity in bytes, little endian |
| 32–33 | UB capacity in 32-bit logical rows, little endian |
| 34–35 | ACC capacity in 32-bit logical rows, little endian |
| 36–37 | WB capacity in 32-bit logical rows, little endian |
| 63 | Device/protocol ID `0xA1` |

Read channel payload only while its VALID status bit is set. It remains stable
across SPI reads until explicitly acknowledged. FIFO empty does not mean compute
or DMA is complete: submit a SYNCHRONIZE instruction and wait for `sync_seen`.

### Action bits

| Bit | Action |
| --- | --- |
| 0 | Acknowledge current AW request |
| 1 | Acknowledge current W beat |
| 2 | Acknowledge current AR request |
| 3 | Submit staged R response if R pending is clear |
| 4 | Submit staged B response if B pending is clear |
| 5 | Enqueue staged instruction if FIFO is not full |
| 6 | Clear sticky synchronization flag |
| 7 | Clear sticky host error |

Acknowledging an invalid channel, submitting into an occupied response slot, or
pushing into a full FIFO sets `host_error`. Rejected response/instruction pushes
leave pending data intact. New errors take priority over clearing. AXI errors
are generated by the original adapter and cleared by reset.

### Host service procedure

1. Reset, read ID `0xA1`, and load instructions through write registers 0–7 and
   action bit 5. The ISA layouts and opcodes are defined in `src/tpu_pkg.sv`.
2. When ARVALID is set, read AR address/length/size/ID, then acknowledge AR.
   Read the requested data from host memory and submit each R beat, with matching
   RID, response code 0 (OKAY), and RLAST set only on the last beat. Wait for
   R pending to clear before submitting the next beat.
3. When AWVALID is set, record its address/length/size/ID, then acknowledge AW.
   For each WVALID beat, read WDATA/WSTRB/WLAST, apply enabled bytes to host
   memory, then acknowledge W. Submit B with the recorded ID and OKAY response
   after the last beat. Service read and write channels as they become valid.
4. Clear `sync_seen`, submit the 64-bit instruction `0x00000000000000FF`, continue
   servicing memory requests, and poll `sync_seen` for completion.

Weights must be preloaded with opcode 0x41 before a WEIGHT instruction selects
a WB row. For example, `(dram_addr << 32) | (wb_row << 16) | (rows << 8) | 0x41`
loads `rows` 32-bit rows, and `(wb_row << 25) | 0x08` selects the local WB row.
The existing INPUT/sparsity stream supplies the associated scalar and mask.

For example, `0x0000100000000240` loads two two-element FP16 rows from byte
address `0x1000` into unified-buffer rows 0 and 1. Each AXI beat is 64 bits,
so these two rows share one beat; a single-row store uses byte strobe 0x0F.
`test/test.py` contains a working pin-level host implementation and examples.

## External hardware

An SPI master (microcontroller or FPGA) plus a continuous system clock and reset.
The host must run the memory-service protocol above and provide storage for the
TPU's external tensors. Use IO levels appropriate to the Tiny Tapeout carrier.

### Local synthesis

Local Synopsys synthesis scripts and P&R experiments live in excluded `syn/`
and `pnr/` directories. GitHub Actions uses `src/config.json` (512 B) and the
checked-in OpenRAM views instead. The default RTL and test capacity is also 512 B.

Latest local pre-layout result after DMA FIFO/address/count/register sharing
optimizations, at 100 ns with analytical TT SRAM timing:

| Version | Standard cells (um2) | SRAM (um2) | Total (um2) | 8x2 tile |
|---|---:|---:|---:|---:|
| Before DMA optimization, 512 B |141104.077|97582.711|238686.788|76.72%|
| Current, 512 B |122288.532|97582.711|219871.243|70.67%|

DMA area decreased from 31315.033 to 12549.536 um2. The 372-transfer DMA test
and both integration tests passed. Setup slack is 27.42 ns with zero setup TNS;
hold and max-transition violations remain. These are raw cell-area sums,
not proof that placement/routing or chip-level DRC/LVS will pass.

The `ci/sram-only-512b` branch isolates the same 512 B macro with a minimal
wrapper so its Actions result can be compared with the full accelerator.
