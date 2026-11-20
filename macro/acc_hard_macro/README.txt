FP8 accelerator candidate with buffered 1 KiB SRAM — 2026-11-20

Source commit: e02c2fefcd3f25784fbb0113be88257d3f61004f
Fresh DC synthesis + ICC2 PnR, 20 ns target.
Core GDS top: acc_hard_macro (not the complete Tiny Tapeout wrapper).
Core size: 1367.12 x 214.88 um; wrapper placement contract: (5.52,5.44), N.
Right-side SRAM origin inside core: (514.785,0.265), R0.
GDS contains actual standard-cell and buffered SRAM geometry.
Only the PR boundary was added; DBU was exactly converted to 1 nm with no rounding.
LEF is a conservative used-layer frame; wrapper pin-access closure is not claimed.

Final standard-cell utilization: 59.15%, excluding SRAM and keepouts.
Placement legality, route DRC, opens, antenna, PG DRC/connectivity: pass.
Two physical antenna diodes protect the SRAM constant-input net; no RTL ECO.
Nominal internal setup slack +4.85 ns; minimum hold slack +0.01 ns.
Remaining electrical constraints: 64 SRAM-output max-capacitance violations,
one max-transition violating net (0.750427 ns vs 0.750000 ns), and external IO
timing failures under the historical 20 ns IO budgets.

Candidate only, NOT tapeout signoff. SRAM Liberty is analytical. No full-wrapper
PnR, merged-GDS foundry DRC/LVS or multi-corner STA was performed here.
The LVS files are regenerated connectivity-preserving inputs, not a claim of
extracted-layout LVS completion. 19,608 physical instances and 75,388 supply/well
connections were checked from the generated input netlist.

See checks/ for reports and manifest.json for hashes/provenance.
GitHub's existing gds workflow independently hardens the RTL wrapper; it does not
consume this prebuilt core GDS automatically.
