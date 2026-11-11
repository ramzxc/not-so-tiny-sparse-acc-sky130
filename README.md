# 512 B SRAM macro isolation experiment

This branch hardens one OpenRAM `tt_sram_1rw_64x64_sky130` macro and a small
byte-access wrapper in the same Tiny Tapeout SKY130 8×2 tile as the accelerator.
Only `src/project.v` is compiled. Accelerator source files remain in the repository
for comparison but are excluded from this experiment's synthesis and simulation.

The capacity, physical placement, clock period and hardening flow match the 512 B
accelerator experiment. This branch regenerates the macro with detailed routing
obstructions (`detailed_lef=True`) so internal met3 pins can be reached through
actual free met4 geometry. There is no DMA, AXI adapter, SPI host or memory controller.
The wrapper contains a 64-bit write shift register and an eight-byte read mux.

Run `make -C test` for RTL simulation. GitHub Actions also runs hardening,
Tiny Tapeout precheck, and gate-level simulation. See [pin protocol](docs/info.md).

The macro Liberty uses analytical timing. An Actions pass is an integration result,
not a substitute for SRAM characterization or foundry signoff.

Regenerate only the 512 B variant with `python3 memory/openram/build.py 64 --geometry-only`,
then run `memory/openram/verify.py` and `memory/openram/tests/test_models.py` on
`memory/openram/runs/64x64_custom_tapped`. Package the verified result with
`python3 memory/openram/package.py --words 64`. See the OpenRAM README for tool
environment setup. The 1 KiB variant is not rebuilt by this experiment.

`src/pdn.tcl` keeps the standard TT grid and adds explicit met4 extensions across
the SRAM placement halo to the top/bottom met3 power rings. The extensions stay
outside the array interior. Power connectivity and downstream DRC/LVS checks
remain enabled; macro-level checks and full-chip checks are separate results.
