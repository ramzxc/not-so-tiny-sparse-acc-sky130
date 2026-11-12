Hardened accelerator integration experiment
==========================================
512 B OpenRAM SRAM, two lanes, one physical MAC.
Core extracted from ICC2 run final_1794485759; RTL baseline b22cd30.
Placed as wrapper instance core at (5.52, 5.44) um, orientation N.
Core SIZE: 1367.12 x 214.88 um. Parent TT 8x2: 1378.16 x 225.76 um.
Synthesis uses blackbox.v. Physical flow uses LEF and merged GDS.
Hierarchical nominal TT STA uses acc_hard_macro.v and the extracted SPEF.
LVS and gate simulation use the powered acc_hard_macro.pg.v netlist.
SRAM Liberty, LVS SPICE and simulation model remain in memory/openram/generated.
The raw ICC2 exports are preserved, not rewritten to suppress errors.
PDN feeds are derived from the fixed wrapper power contract, not a shifted grid.

Validation before push:
- ICC2 final route DRC/open nets and PG DRC: zero in exported reports.
- SRAM 134 cells and used standard-cell 152 cells match source GDS polygons
  and reference transforms. No unresolved GDS references. See merge_validation.json.
- Wrapper/header lint: passed.
- Local Icarus powered-netlist simulation: SPI/DMA roundtrip passed;
  shared-memory compute/activation failed with X data at test/test.py:249.
  See reports/local_core_gl.xml. This failure is unresolved, not waived.
- Full merged-GDS foundry-rule DRC/LVS/antenna and wrapper Actions pending.
This experiment is NOT a signoff-approved tapeout release.
