# How it works

One 512 B OpenRAM SRAM (`64 × 64` useful bits, plus an unused spare bit per word)
is connected directly to a byte-access wrapper. The project occupies 8×2 tiles
so that hardening can be compared with the full accelerator using the same macro.
No accelerator, DMA, AXI, SPI, or SRAM arbitration logic is instantiated.

`ui_in[5:0]` selects the word address. `ui_in[6]` selects write (1) or read (0).
`ui_in[7]` enables a memory access. `uio_in` always acts as an input; its output
and output-enable signals are zero.

# How to test

1. Keep `ui_in[7]=0`, `ena=1`, and `rst_n=1`. Present eight bytes on `uio_in`,
   most significant byte first, one byte per rising clock edge. This fills the
   64-bit write buffer.
2. Set `ui_in={1'b1,1'b1,address}` for one clock cycle to write the buffered word.
   The macro samples commands at the rising edge and writes at the falling edge.
3. Set `ui_in={1'b1,1'b0,address}` to read. Select output byte 0 through 7 with
   `uio_in[2:0]`. `uo_out` provides that byte after the falling edge and macro
   access delay. Byte 0 is bits 7:0. Keep read enabled while reading all eight bytes.
4. Reset clears the write buffer and suppresses memory operations but does not
   erase SRAM. `ena=0` suppresses memory accesses and write-buffer shifting.

The cocotb test writes and reads every address with asymmetric data, overwrites
all words, and checks disabled/reset cycles cannot modify stored memory.
It uses the same public pin interface for RTL and gate-level simulation.

# External hardware

A controller that drives the eight input pins and eight bidirectional input pins,
and samples the eight output pins. No external RAM is required.
