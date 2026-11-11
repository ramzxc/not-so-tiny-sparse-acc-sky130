# 512 B SRAM macro isolation experiment

This branch hardens one OpenRAM `tt_sram_1rw_64x64_sky130` macro and a small
byte-access wrapper in the same Tiny Tapeout SKY130 8×2 tile as the accelerator.
Only `src/project.v` is compiled. Accelerator source files remain in the repository
for comparison but are excluded from this experiment's synthesis and simulation.

The macro, physical placement, clock period and hardening flow match the 512 B
accelerator experiment. There is no DMA, AXI adapter, SPI host or memory controller.
The wrapper contains a 64-bit write shift register and an eight-byte read mux.

Run `make -C test` for RTL simulation. GitHub Actions also runs hardening,
Tiny Tapeout precheck, and gate-level simulation. See [pin protocol](docs/info.md).

The macro Liberty uses analytical timing. An Actions pass is an integration result,
not a substitute for SRAM characterization or foundry signoff.
