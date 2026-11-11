# Sample testbench for a Tiny Tapeout project

This is a sample testbench for a Tiny Tapeout project. It uses [cocotb](https://docs.cocotb.org/en/stable/) to drive the DUT and check the outputs.
See below to get started or for more information, check the [website](https://tinytapeout.com/hdl/testing/).

## Setting up

1. Edit [Makefile](Makefile) and modify `PROJECT_SOURCES` to point to your Verilog files.
2. Edit [tb.v](tb.v) and replace `tt_um_example` with your module name.

## How to run

To run the RTL simulation:

```sh
make -B
```

To run gatelevel simulation, first harden your project and copy `../runs/wokwi/results/final/verilog/gl/{your_module_name}.v` to `gate_level_netlist.v`.

Then run:

```sh
make -B GATES=yes
```

If you wish to save the waveform in VCD format instead of FST format, edit tb.v to use `$dumpfile("tb.vcd");` and then run:

```sh
make -B FST=
```

This will generate `tb.vcd` instead of `tb.fst`.

## How to view the waveform file

The shared activation datapath is checked against the unchanged FP16 helper
functions for all 65,536 binary16 patterns per supported activation, including
output stalls and reset. Run this check and the 512 B memory stress test with:

```sh
make -f Makefile.activation
make -f Makefile.sparsity
make -f Makefile.fifo
make -f Makefile.dma
python -m cocotb_tools.check_results sim_build/dma_opt/results.xml
make -f Makefile.vpu
make -f Makefile.mem SRAM_BYTES=512
python -m cocotb_tools.check_results sim_build/mem_512/results.xml
```

The memory test also resets both halves of accumulated writes before commit,
checking that interrupted operations leave the SRAM contents unchanged.
It fills both shared response slots, checks that writes can bypass a blocked
third read, releases each slot independently, and resets with both slots full.

The VPU check compares 20,000 lane results from the single shared MAC against
the FP16 helpers, including arbitrary binary16 values and reset during each
issue/drain phase. The architectural vector width remains two lanes.

Activation uses one adder/shifter across both lanes. The exhaustive check
still compares every supported function against the unchanged FP16 helpers.
The sparsity check drives 512 entries through the two-entry FIFO, including
full conditions, pointer wrap, independent value/mask stalls, and invalid
addresses. Instruction, DMA and sparsity FIFOs now use two physical entries
with one usable entry. The instruction FIFO check exercises simultaneous
replacement while full, stalls, wrap and reset; the DMA stress test covers
maximum-length transfers, boundaries, odd tails and independent stalls.

Using GTKWave

```sh
gtkwave tb.fst tb.gtkw
```

Using Surfer

```sh
surfer tb.fst
```
