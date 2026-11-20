> Historical baseline from 2026-11-19. For the current RTL, see [2026-11-20 physical fit](current_physical_fit.md).

# Buffered 1 KiB SRAM: synthesis and physical fit

**Result: the current core fits the TT 8×2 envelope and completes placement, CTS, routing and filler insertion.** Final ICC2 legality, route DRC, opens, antenna and PG checks are zero. This is an area/routability pass, not tapeout signoff.

Run: `reports/physical_fit_20261119_211634`. Final block: `pnr/acc_hard_macro.ndm:acc_hard_macro/final_clean.design` under that run. Old design libraries and synthesis outputs were preserved; no functional RTL changes.

| Metric | Value |
|---|---:|
| TT die footprint | 1378.16 × 225.76 µm |
| Standalone core boundary | 1367.12 × 214.88 µm |
| Synthesized logic | 56,783.21 µm² |
| SRAM Liberty area | 180,558.72 µm² |
| Synthesized total | 237,341.93 µm² |
| Final standard-cell area reported for utilization | 53,276.10 µm² |
| Available standard-cell placement capacity | 103,744.50 µm² |
| Final standard-cell utilization | 51.35% |
| Final netlist area, including SRAM | 233,834.81 µm² |
| Area including physical-only cells/fillers | 284,303.22 µm² |

Utilization excludes the macro and placement keepouts. The remaining percentage is not a promise of equally large future logic growth: routing, timing, tap/endcap fragmentation and added fanout still matter. Filler area is not functional logic consumption.

The SRAM remains at core origin (514.785, 0.265), tile origin (520.305, 5.705), R0/N. Actual LEF/GDS outline is 842.335 × 214.355 µm. ICC2 reported cell bboxes can include pin/keepout extents; the audit checks those extents as well as all standard-cell extents against the core boundary.

## Physical fixes in this isolated run

- Built the new buffered SRAM NDM using its current LEF and compiled Liberty DB.
- Updated stale 512B macro selectors for LI blockage and antenna properties; regenerated gate-area bounds from the new SRAM LVS SPICE.
- Preserved right-side SRAM placement and left-side supply feeds. Inserted taps/endcaps, optimized placement, synthesized clocks and routed.
- Added three small diode_2 antenna cells: two on the SRAM constant-input net and one on macro_data[15]. They do not change logical behavior. They are included in the final area.
- Removed 77 isolated M1 PG rail fragments in the unused right keepout. All floating-wire, floating-via, floating-cell, floating-macro and floating-terminal counts are now zero.
- Initial scripts stopped on remaining antenna violations rather than waiving them. Final repair, cleanup and fresh audit are preserved separately.

## Validation and remaining limits

Final saved block was reopened; current antenna rules were explicitly reloaded before audit (ICC2 does not retain these rules merely by opening the saved block). All route/antenna/PG/legality counts pass, and source hashes confirm unchanged functional RTL.

The run targets a 20 ns clock but retains historical 20 ns input/output delays. IO timing is therefore not closed; nominal clock-group setup slack is +4.45 ns, not a board/PVT guarantee. SRAM timing is analytical. No merged-GDS foundry DRC/LVS, full wrapper PnR, gate-level equivalence or multi-corner timing signoff was performed.

Artifacts: [placement preview](../reports/physical_fit_20261119_211634/floorplan.svg), [summary](../reports/physical_fit_20261119_211634/summary.json), [final utilization](../reports/physical_fit_20261119_211634/audit/utilization.rpt), [route/antenna checks](../reports/physical_fit_20261119_211634/audit/routes.rpt), [PG connectivity](../reports/physical_fit_20261119_211634/audit/pg.rpt), [legality](../reports/physical_fit_20261119_211634/audit/legality.rpt).

Reproduction scripts in the run: `synth.tcl`, `lm.tcl`, `pnr.tcl`, `finish.tcl`, `finish2.tcl`, `cleanup.tcl`, `audit.tcl`. Source/config snapshots and hashes are retained. Final DEF is `audit/layout.def`; the saved NDM includes intermediate checkpoints. No submission artifacts or syn/LATEST pointer were replaced.
