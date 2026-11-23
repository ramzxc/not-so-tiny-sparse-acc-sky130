# 4-lane FP8 accelerator layout

This is the GDS export of the optimized ICC2 checkpoint from
`quad_local_fc_50mhz_20261123_155755_x3PhPW`. The core uses four FP8 MACs,
four FP8 lanes per logical SRAM row, and one 512-byte SRAM macro. It was
routed for a 20 ns clock on the existing 8×2 floorplan.

- `acc_native_fp8_macro.gds` contains the routed core, SKY130HD cell
  geometry, and the embedded 512-byte SRAM geometry.
- `rtl/` is the source snapshot from the synthesis run, in compilation
  order in `rtl/sources.f`. The SRAM simulation model is supplied by the
  existing OpenRAM macro sources in this project.
- `acc_native_fp8_macro.routed.v` and the matching SDC come from the same
  PnR run.
- `reports/` contains the export and physical checks. ICC2 reported
  59.54% optimized placement utilization and zero routing DRCs, opens,
  and antenna violations.

The wrapper uses the matching packaged views under `macro/acc_hard_macro/`.
The run still reported internal setup slack of -0.01 ns, generic I/O
setup violations, and 35 floating wire fragments on each supply net.
No standard cells or hard macros were reported floating. Full-chip
DRC/LVS and timing signoff are pending.
