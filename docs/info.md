## Overview

The Tiny Tapeout project wraps a hardened SKY130 accelerator with four FP8
E4M3FN MAC lanes and a 512-byte SRAM. It streams sensor inputs from UART,
fetches instructions and weights from an external QPI PSRAM, and returns two
FP8 output values per computation over UART.

## Board connection

Use the TinyQV QSPI Pmod pin order. Prepare PSRAM-A in QPI mode and load the
program image before releasing chip reset and giving the accelerator the
bus. At the 50 MHz target clock, the UART uses 8N1 with 87 clock cycles per
bit, or about 574.7 kbaud.

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
(1–4). The repeat table begins at `0x1ff000` and the instruction stream
starts at `0x200000`. Send input bytes after the ready signal. Pad an odd
channel count with one zero byte. The chip transmits the two output values
as separate bytes, lowest byte first. In this core version, the FC result
write at `0x3800` is captured for UART locally.

## Implementation

The wrapper instantiates the `acc_hard_macro` view in
`macro/acc_hard_macro/`. The physical views use one routed 4-lane core
checkpoint. The corresponding source snapshot is in
`layout/quad-fp8-50mhz/rtl/`. The wrapper smoke test exercises QPI boot,
UART ingress, SRAM DMA, an FP8 vector operation, and UART egress through
the public pins.
