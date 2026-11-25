## Overview

The Tiny Tapeout project wraps a hardened SKY130 accelerator with four FP8
E4M3FN MAC lanes and a 512-byte SRAM. It streams sensor inputs from UART,
fetches instructions and weights from an external QPI PSRAM, and returns two
FP8 output values per computation over UART.

## Board connection

Use the TinyQV QSPI Pmod pin order. Prepare PSRAM-A in QPI mode and load the
program image before releasing chip reset and giving the accelerator the
bus. The UART uses 8N1. At 50 MHz, the default of 87 clock cycles per bit
gives about 574.7 kbaud.

| Tiny Tapeout pin | Function |
| --- | --- |
| `ui[3]` | UART RX |
| `uo[4]` | UART TX |
| `uo[2]` | Decoder ready |
| `uo[1]` | Fault |
| `uio[1,2,4,5]` | QPI DQ0–DQ3 |
| `uio[3]` | QPI clock |
| `uio[6]` | PSRAM-A chip select, active low |
| `uio[0,7]` | Other memory chip selects, held high |

## Boot and output

The PSRAM image has an eight-byte little-endian header at `0x1ffff8`. Bits
8:0 give the input channel count (1–256), and bits 11:9 give the batch size
(1–4). The RTL reads the UART clocks per bit from bits 21:12. Use zero for
the default (87), or set a divisor from 32 to 1023. Bits 63:22 are reserved
and must be zero. The MCU writes this value before reset is released, and
the same setting applies to RX and TX until the next reset. The current
routed GDS uses the default and requires a zero in bits 63:12.
The repeat table begins at `0x1ff000` and the instruction stream
starts at `0x200000`. Send input bytes after the ready signal. Pad an odd
channel count with one zero byte. The chip transmits the two output values
as separate bytes, lowest byte first. In this core version, the FC result
write at `0x3800` is captured for UART locally.

## Implementation

The wrapper instantiates the `acc_hard_macro` view in
`macro/acc_hard_macro/`. The physical views use one routed 4-lane core
checkpoint with the earlier SRAM layout. The current source in
`src/rtl/` fixes the 512-byte SRAM map at 128 B UB,
256 B ACC, and 128 B WB. Generate the matching batch-1 FP8 EGRU/FC image
with `scripts/build_column_egru.py`. Full 256-neuron accumulation uses a
64-row repeat descriptor and updates ACC in two 32-row passes over WB.
Programs can also tile their work and spill/reload FP8 partial sums with
`ACC_TO_DRAM` and `DRAM_TO_ACC` when their working set exceeds 256 B.
The new SRAM map requires a new physical build.

The source list is `src/sources.f`. The accelerator datapath, DMA and
program sequencer live in `src/rtl/core/`. UART and the QPI bridge live in
`src/rtl/peripherals/`. The synthesizable accelerator and SRAM macro
wrappers live in `src/rtl/macros/`. Legacy FP16 RTL uses its own file list
at `src/legacy/sources.f`. Testbenches and peripheral models are under
`test/rtl/`. The wrapper smoke test exercises QPI boot,
UART ingress, SRAM DMA, an FP8 vector operation, and UART egress through
the public pins.
