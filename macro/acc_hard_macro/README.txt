FP8 accelerator hard macro integration candidate — 2026-11-21

Latest RTL source: 55110b9e8135b4f3984fed301c44e32e054140d8.
Fresh DC synthesis and ICC2 placement/routing at a 20 ns clock target.
Core: acc_hard_macro, 1367.12 x 214.88 um, placed at (5.52,5.44) in the TT 8x2 wrapper.
The right-side buffered 1 KiB SRAM is inside this core GDS.
Wrapper synthesis now uses this core as a black box. Final GDS merges real core
geometry; STA uses its powered netlist/SPEF, and LVS compares its full circuit.
No functional RTL changes. Two explicit reset AND gates preserve the RTL reset
behavior for micro acc_addr[7] and DMA destination[8] in four-state simulation.
Antenna-cell body connections and post-route filler gaps were repaired.

See checks/ for this build's physical and functional results. These replace the
previous candidate's reports. Nominal-only RC and analytical SRAM Liberty remain
limitations. Historical standalone 20 ns IO budgets are not closed, and electrical
violations remain. Full-wrapper CI status is recorded separately; this package
alone is not tapeout signoff.
