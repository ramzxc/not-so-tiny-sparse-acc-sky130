> This physical result predates the interface grouping into `input_queue`, `command_ctrl`, and `qspi_ctrl`. That RTL refactor has not been synthesized or routed again; the exact physical-run sources remain in its snapshot.

# Current RTL physical fit — 2026-11-20

The current RTL fits the standalone Tiny Tapeout 8×2 core envelope with the
buffered 1 KiB SRAM on the right. Placement, CTS, detailed routing, route
optimization and filler insertion completed. This is an area/routability pass;
it is not a tapeout timing or foundry signoff.

Run: `reports/physical_fit_20261120_172107`. Saved block:
`pnr/acc_hard_macro.ndm:acc_hard_macro/final_clean.design` under that run.
The run includes the uncommitted one-word UART FIFO, autonomous PSRAM ingress
queue and sustainable-stream compute/SRAM optimizations. No functional RTL was
changed for synthesis/PnR. Source and macro hashes were verified after the run.
Old checkpoints, `syn/LATEST` and published macro artifacts were preserved.

| Metric | Previous 2026-11-19 | Current |
|---|---:|---:|
| Synthesized logic, excluding SRAM | 56,783.21 µm² | 64,645.75 µm² |
| Synthesized SRAM | 180,558.72 µm² | 180,558.72 µm² |
| Synthesized total | 237,341.93 µm² | 245,204.47 µm² |
| Final standard-cell area used for utilization | 53,276.10 µm² | 60,950.96 µm² |
| Available standard-cell placement capacity | 103,744.50 µm² | 103,744.50 µm² |
| Final utilization | 51.35% | **58.75%** |
| Netlist area including SRAM | 233,834.81 µm² | 241,509.68 µm² |

Utilization excludes hard macros and macro keepouts; it is not logic area divided
by the full die area. About 42,793.54 µm² of that capacity remains unused by the
reported logic cells. This does not guarantee equally large future logic growth:
placement fragmentation, timing and routing also constrain expansion. Fillers
occupy unused sites and are not additional functional logic demand.

The 1-word FIFO hierarchy synthesizes to 579.31 µm², including its 16-bit storage
and valid/control logic. This is an absolute module area, not an incremental cost
versus the previous `write_word`/`pending` registers. The overall increase also
includes the PSRAM frame queue and prior compute optimizations; it cannot be
attributed to FIFO reuse alone.

## Geometry and checks

- TT die: 1378.16 × 225.76 µm; standalone core: 1367.12 × 214.88 µm.
- SRAM origin: (514.785, 0.265) in the core, R0; unchanged right-side placement.
- All final instance bounds fit inside the standalone core boundary.
- Placement legality, route DRC, open nets and antenna violations: **0**.
- PG DRC and all floating wire/via/cell/macro/terminal counts: **0**.
- Removed the same 77 unused right-keepout M1 rail fragments as in the prior run.
- No manual antenna diode ECO was needed in this run.

## Timing and remaining electrical constraints

The 20 ns clock gives nominal internal register-to-register setup slack of
**+4.80 ns**, with no reported internal setup/hold violations. Minimum hold slack
rounds to +0.00 ns at the report's precision, so this is not a claim of substantial
hold margin. Community technology/nominal RC and analytical SRAM Liberty are used.
External IO constraints still use historical 20 ns input/output delays and fail;
these results do not establish board-level 50 MHz timing closure.

The final saved block's fresh constraint report shows **64 max-capacitance
violations, all at SRAM `dout0[63:0]`**. The worst is `dout0[61]`: 0.186570 pF
load versus a 0.027560 pF limit. Max-transition violations are zero. The initial
in-session final QoR showed 14 capacitance violations; the reopened, freshly
extracted report is the conservative result used here. The prior physical audit
also reported 64 capacitance violations. These have not been repaired or waived.
SRAM output drive/load must be resolved before claiming electrical signoff.

No full-wrapper PnR, merged-GDS foundry DRC/LVS, equivalence check or multi-corner
STA was performed. The present area result does not require a functional
tradeoff, but it does not make the design tapeout-ready.

## Evidence

- [Placement preview](../reports/physical_fit_20261120_172107/floorplan.svg)
- [Machine-readable summary](../reports/physical_fit_20261120_172107/summary.json)
- [Utilization](../reports/physical_fit_20261120_172107/audit/utilization.rpt)
- [Routing and antenna](../reports/physical_fit_20261120_172107/audit/routes.rpt)
- [Power connectivity](../reports/physical_fit_20261120_172107/audit/pg.rpt)
- [Internal setup timing](../reports/physical_fit_20261120_172107/audit/internal_setup.rpt)
- [Detailed electrical constraints](../reports/physical_fit_20261120_172107/audit/constraints.rpt)

Reproduction scripts, input snapshot and hashes are retained under the run:
`env.sh`, `synth.tcl`, `pnr.tcl`, `finish_audit.tcl`, `constraints.tcl`,
`snapshot/`, and `manifest.json`.
