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

## Independent RTL CI failure and correction

[Run 44720387698](https://github.com/ramzxc/not-so-tiny-sparse-acc-sky130/actions/runs/44720387698)
failed with Magic DRC 56, KLayout DRC 2 and LVS 745. This was the separately
hardened RTL wrapper, not a check of the published ICC2 core above.

The CI reference incorrectly selected the original SI-unit SRAM SPICE instead
of the active-PDK micron model. Its ascending SPICE bus declarations also caused
Netgen to bind named Verilog bus concatenations in reverse order. Preparing and
selecting the descending-bus model fixes LVS on the **unchanged** CI extraction;
the full comparison matches uniquely with zero property errors. An intentionally swapped
SRAM address-bit reference still fails LVS. The positional SPICE used by the
prebuilt ICC2 core is unchanged.

The two physical DRC locations were SRAM VPWR M3 feeds approaching VGND row-via
landings by approximately 0.1 µm. The feeds now jog 0.6 µm near the left straps,
then return to the original path before the SRAM signal-pin region. Feed width
stays 1.74 µm. The corrected-layout experiment passes KLayout DRC, and rerunning
the actual PDN Tcl on the CI database confirms both supply networks connected.

The previous gate-test entry point explicitly rejected `GATES=yes`. It now tests
the current routed wrapper through package pins, including MICRO batch 1 and 3,
replay, enable gating, and raw UART frames stored/consumed through PSRAM. Both
tests pass on the failed CI run's routed netlist at a 50 MHz simulation clock.
This remains functional GLS with the SRAM behavioral model and no SDF.

Local evidence: [CI correction report](../reports/ci_gds_fix_20261120/summary.json).
A newly routed full CI run is still required after these configuration changes.

The Actions summary also now identifies the flow from the final DEF. An RTL run
uses its own cell inventory and wire length; it does not add the separate ICC2
core a second time. The displayed OpenROAD standard-cell utilisation explicitly
states that its macro-excluded denominator is not the stricter row capacity
with all placement keepouts removed.
