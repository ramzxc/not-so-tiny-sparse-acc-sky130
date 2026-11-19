> Subsequent synthesis/PnR completed successfully; see [physical_fit.md](physical_fit.md) for current measured results and signoff limits.

# Buffered SRAM: right-side placement

The 2026-11-19 buffered 1 KiB SRAM is imported from the sibling
`not-so-tiny-sparse-acc-sky130-ci-fp8-1k/memory/openram/runs/1kib_output_buffer_20261119`
run. The active macro is `tt_sram_1rw_64x128_buffered_sky130`.
Physical views come from `repaired/`; functional and timing views come from
`full/`. Import paths and hashes are recorded in the generated macro's
`import.json`. The original macro is retained for historical results.

| Geometry | Value (µm) |
|---|---|
| Macro width × height | 842.335 × 214.355 |
| Tile origin, lower left | 520.305, 5.705 |
| Tile upper right | 1362.640, 220.060 |
| Core-relative origin | 514.785, 0.265 |
| Core rectangle in tile | (5.52, 5.44)–(1372.64, 220.32) |
| Left logic width, excluding keepout | 504.785 |
| Horizontal keepout | 10 per side |
| Core clearance, bottom / top | 0.265 / 0.260 |

Orientation is N (ICC2 R0). Clock and control pins face the logic region on
the left. Vertical keepout is zero because the macro occupies almost the full
core height. These dimensions establish containment, not routing feasibility.

`src/config.json` selects all new macro views and the right-side location.
`src/tcl/pdn.tcl` connects the actual horizontal M3 supply rings to the nearest
same-net full-height M4 stripe on the left. A full-height M4 obstruction covers
the macro and its horizontal keepout. ICC2 local setup and PG geometry use the
same placement, translated to core coordinates. Vias are placed at the outside
supply columns, not at the macro's crossed outer supply ring.

The local synthesis library binding selects the buffered Liberty/DB. Library
Compiler generated the DB; no new RTL synthesis was run. ICC2 requires a fresh
buffered NDM via `pnr/scripts/rebuild_sram_ndm.tcl` and a matching fresh netlist.
Existing live blocks and old NDMs were not modified. Local `pnr/` and `syn/`
files are ignored by Git; retain them separately when reproducing this flow.

## Validation

- Default PSRAM stream suite with the new SRAM model: 4 passed, 0 failed.
- Verilator lint: no errors; imported SRAM model retains its 64-bit X literal
  assignment to a 65-bit physical output warning.
- `python3 scripts/check_sram_placement.py`: macro/core containment, keepout,
  control-pin direction, imported GDS/SPICE hashes, cross-flow coordinates,
  PG lead/column/ring geometry and Tcl completeness pass.
- Geometry report: `reports/sram_right/placement.json`.
- Geometry preview: `reports/sram_right/floorplan.svg` (not a routed layout).

The source SRAM reports standalone physical DRC/LVS success. This does not
validate the integrated layout. Placement/routing, integrated PDN connectivity
and DRC, signal access and extracted timing have not been run for this change.
The imported Liberty is analytical, not extracted full-SRAM characterization.
Earlier area/performance reports are historical and must not be presented as
measurements of this buffered integration.
