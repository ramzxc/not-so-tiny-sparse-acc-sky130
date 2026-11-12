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
The raw ICC2 exports remain in the source run. The packaged GDS adds the
LEF-sized 235/4 PR boundary and exactly converts DBU from 0.1nm to 1nm for
Magic compatibility. No geometry is rounded or moved; see boundary_validation.json
and units_validation.json. All other records and reference transforms are preserved.
PDN feeds are derived from the fixed wrapper power contract, not a shifted grid.

Validation before push:
- ICC2 final route DRC/open nets and PG DRC: zero in exported reports.
- SRAM 134 cells and used standard-cell 152 cells match source GDS polygons
  and reference transforms. No unresolved GDS references. See merge_validation.json.
- Wrapper/header lint: passed.
- Local Icarus powered-netlist simulation: SPI/DMA roundtrip passed;
  shared-memory compute/activation failed with X data at test/test.py:249.
  See reports/local_core_gl.xml for the original failing run.
- Resolved GL X-pessimism in reset feedback on two activation address bits:
  test/check_icc2_reset.py proves both D inputs zero for all 1024 binary
  input/feedback assignments each. test/icc2_reset_x.vh applies only while
  all three reset predicates are known and asserted, releasing otherwise.
  No Q forcing, SRAM initialization, or netlist/GDS modification is used.
  The powered-netlist integration tests now pass 2/2, including ReLU,
  sigmoid/tanh and FIFO wrap: reports/local_core_gl_reset_corrected.xml.
- Actions initially rejected unescaped '!' in ICC2 SPEF NAME_MAP filler names.
  scripts/prepare_opensta_spef.py writes acc_hard_macro.opensta.spef.gz for
  Actions. Raw SPEF retained. Only name escaping differs; RC sections unchanged.
  Converted file successfully parsed with local OpenSTA 2.7.0. This parser
  check is not a complete timing signoff; annotation coverage still needs review.
- Full merged-GDS foundry-rule DRC/LVS/antenna and wrapper Actions pending.
This experiment is NOT a signoff-approved tapeout release.
