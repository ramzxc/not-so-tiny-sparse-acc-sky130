## How it works

Four-lane FP16 sparse accelerator imported from `/docker/projects/egru/acc/rtl`
(with `lib/tpu_pkg.sv`). The original source directory is preserved. The TPU,
instruction FIFO, DMA, weight cache, vector unit, and activation unit are connected
through an SPI host bridge. The host supplies external memory: SPI does not connect
directly to an SPI flash or PSRAM chip.

The original FreePDK45 SRAM instances in the unified buffer, weight buffer, and
accumulator are replaced by `acc_memory_1r1w_64x256`, a synthesizable 256 x 64-bit
memory with a synchronous read port and independent write port. Memory contents
are not reset; software must load operands before using them. Same-address
simultaneous reads and writes return the old word; the existing core forwarding
logic handles dependencies.

This is an RTL integration, not a verified 8x2-tile physical implementation.
Portable memories map to standard cells, and the full-size FP16 core and cache
may require substantial area reduction or a supported SKY130 SRAM integration.
No SKY130 synthesis, timing closure, place-and-route, DRC, or LVS result is claimed.

The top module is `tt_um_not_so_tiny_sparse_acc_ramzxc`. `rst_n=0` resets the
interface and accelerator. `ena=0` also holds them in reset; deselection discards
in-flight work. The system clock target is 10 MHz (`CLOCK_PERIOD=100` ns).
`USE_SLANG` enables package/packed-type support in the LibreLane synthesis flow;
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
FP16 vector addition and accumulator readout, error reporting, and deselection.
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
| 0 | `[7]=host_error`, `[6]=axi_error`, `[5]=sync_seen`, `[4]=FIFO full`, `[3]=FIFO empty`, `[2]=ARVALID`, `[1]=WVALID`, `[0]=AWVALID` |
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

For example, `0x0000100000000240` loads two four-element FP16 rows from byte
address `0x1000` into unified-buffer rows 0 and 1. Each AXI beat is 64 bits.
`test/test.py` contains a working pin-level host implementation and examples.

## External hardware

An SPI master (microcontroller or FPGA) plus a continuous system clock and reset.
The host must run the memory-service protocol above and provide storage for the
TPU's external tensors. Use IO levels appropriate to the Tiny Tapeout carrier.
