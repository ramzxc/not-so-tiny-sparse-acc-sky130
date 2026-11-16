## How it works

An FP16 sparse accelerator for **Tiny Tapeout SKY130**, using **8×2 tiles**.
It combines a two-lane compute engine, an SPI host interface, and a shared 512 B SRAM.

### Features

- Two FP16 lanes sharing one physical MAC.
- Sparsity control and ReLU, sigmoid, and tanh activation.
- Software-managed weights and memory accumulation.
- One 512 B OpenRAM SRAM, shared by UB (256 B), ACC (128 B), and WB (128 B).
- SPI host interface and DMA request handling.
- Two-entry instruction FIFO and a 10 MHz target clock.

### Architecture

```text
Tiny Tapeout pins → Wrapper → Accelerator core
                             ├─ SPI host and DMA
                             ├─ Compute, sparsity, and activation
                             └─ Memory controller → 512 B SRAM
```

The core is synthesized with Design Compiler and placed and routed with ICC2.
The Tiny Tapeout flow imports the finished core and builds the wrapper around it.

### Shared memory

The 512 B SRAM is a 64-bit × 64-word OpenRAM macro. The memory controller
shares it between three regions. Each logical row holds two FP16 values
(32 bits); two logical rows share one physical SRAM word.

| Region | Capacity | Logical rows |
| --- | --- | --- |
| UB | 256 B | 64 |
| ACC | 128 B | 32 |
| WB | 128 B | 32 |

Software loads weights into WB before use. The controller also supports
accumulating results into memory. SRAM contents are not cleared by reset,
so software must load input data before reading it.

The submitted core uses 512 B. A different SRAM capacity requires a new
core synthesis and place-and-route run.

The SRAM timing library uses analytical estimates rather than SPICE
characterization. See [the SRAM documentation](../memory/openram/README.md).

### Clock and reset

The target system clock is 10 MHz. `rst_n=0` resets the interface and core.
`ena=0` also holds them in reset and discards in-flight work. A running system
clock is required for both SPI communication and computation.

### Source files

| Path | Contents |
| --- | --- |
| `src/wrapper/` | Tiny Tapeout top module |
| `src/rtl/` | Accelerator RTL |
| `src/tcl/` | PDN and Magic scripts used by Actions |
| `src/config.json` | Current 512 B integration settings |
| `macro/acc_hard_macro/` | Core GDS, LEF, netlists, and SPEF |
| `memory/openram/` | SRAM generator and macro files |
| `test/` | RTL and gate-level tests |
| `scripts/` | Integration and reporting tools |
| `docs/` | Interface documentation and archived notes |

#### Netlists

- **Post-route, including power pins:** [acc_hard_macro.v](../macro/acc_hard_macro/acc_hard_macro.v)
- **Post-synthesis, local build:** `syn/runs/<run>/acc_hard_macro_gate.v`

## How to test

Requires Python, Make, and Verilator 5.036 or newer. CI uses Verilator 5.052.
Run from the repository root:

```sh
python3 -m pip install -r test/requirements.txt
make -C test SRAM_BYTES=512
python3 -m cocotb_tools.check_results test/results.xml
```

GitHub Actions runs RTL tests, wrapper hardening, DRC/LVS, Tiny Tapeout precheck,
and gate-level simulation. Build results include a 2D preview and a 3D viewer link.

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
| `0x00 \| address` | Dummy byte; read result appears on MISO | Read register |
| `0x40 \| address` | Data | Write staging register |
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
   action bit 5. The ISA layouts and opcodes are defined in `src/rtl/tpu_pkg.sv`.
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
