# Hardened core integration experiment

Branch: `experiment/hard-macro-integration`. Functional RTL source: `55110b9`.

The wrapper now instantiates the packaged `acc_hard_macro` as a synthesis black box.
Final GDS merges its actual standard cells and buffered 1 KiB SRAM; timing uses
its powered netlist and SPEF, and LVS uses the complete circuit. The existing
`experiment/sustainable-stream` branch retains the RTL-hardening comparison.

The core occupies 1367.12 × 214.88 µm at (5.52, 5.44) inside the TT 8×2 tile.
The SRAM stays on the right. Power feeds are generated from the 13 VPWR and
13 VGND continuous M4 columns verified against the actual GDS, replacing the
old 512B-specific power contract. Wrapper `ena` output gating is retained.

Fresh DC/ICC2 output initially exposed two four-state reset feedback issues:
micro `acc_addr[7]` and DMA `destination[8]`. Two explicit reset AND gates fix
initialization without changing the binary function; the two reset cones were
checked with combinational SAT. This is a physical netlist ECO, not an RTL edit.
Antenna-diode body connections and filler gaps were also repaired.

Local validation:
- Pin-level post-route core simulation: 2 tests passed, including batch 1/3,
  replay, UART-to-PSRAM queue, and `ena` gating. Behavioral memory, no SDF.
- Standalone merged-GDS Magic DRC: zero violations.
- ICC2 legality, route opens/DRC/antenna and PG checks: see current reports.
- Powered-netlist supply/body connections: 19,610 instances, 75,396 pins checked.
- OpenROAD geometry-based logic utilization: 59.03%, excluding SRAM/keepouts,
  filler and taps. This includes physical antenna cells and differs slightly
  from ICC2's utilization accounting.

Full wrapper GDS, LVS, gate simulation and Tiny Tapeout precheck are validated
by the branch's GitHub Actions run; local results above do not imply CI success.
The nominal-only RC and analytical SRAM Liberty are not signoff models. Historical
standalone 20 ns IO budgets are not closed and electrical violations remain.
See `macro/acc_hard_macro/manifest.json` and `checks/` for source hashes and evidence.
