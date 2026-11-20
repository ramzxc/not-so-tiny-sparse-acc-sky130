# Published core GDS candidate — 2026-11-20

Fresh synthesis and PnR of source commit `e02c2fefcd3f25784fbb0113be88257d3f61004f`,
including `core/command_ctrl`, integrated QSPI arbitration and the one-word UART
input queue. Local run: `reports/gds_publish_20261120_191712`; ICC2 export:
`pnr/runs/final_1795170711`. This is the standalone core GDS, not the final wrapper.

| Check | Result |
|---|---:|
| Standard-cell utilization, excluding SRAM/keepouts | 59.15% |
| Standard-cell area | 61,365.10 µm² |
| Placement capacity | 103,744.50 µm² |
| Nominal internal setup / hold slack | +4.85 / +0.01 ns |
| Placement / route DRC / opens / antenna / PG checks | 0 violations |
| SRAM-output capacitance violations | 64 |
| Transition-violating nets | 1 |

Two physical diode cells repaired the SRAM constant-input antenna violations.
Unused right-keepout power rail fragments were removed, and the saved result
was reopened and checked before export. GDS references are resolved, actual
SRAM geometry is included, and the core bounds are 1367.12 × 214.88 µm. GDS
normalization changes database units exactly without rounding manufacturing
geometry. The LVS source and physical inventory were regenerated from the same
powered netlist. Their hashes and power connections were checked.

This is an inspectable candidate, **not tapeout signoff**. The remaining SRAM
load and transition constraints are not waived. Historical external IO timing
budgets fail; SRAM timing is analytical and the RC corner is nominal only.
Merged-GDS foundry DRC/LVS, full-wrapper PnR and multi-corner timing have not been
completed for this candidate. The existing GitHub workflow builds the RTL wrapper
independently, rather than importing this prebuilt core.

- [GDS](../macro/acc_hard_macro/acc_hard_macro.gds)
- [Package description](../macro/acc_hard_macro/README.txt)
- [Source and artifact hashes](../macro/acc_hard_macro/manifest.json)
- [Placement preview](../macro/acc_hard_macro/checks/floorplan.svg)
- [Physical measurements](../macro/acc_hard_macro/checks/physical_fit.json)
- [Electrical constraints](../macro/acc_hard_macro/checks/constraints.rpt)
