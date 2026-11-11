# OpenRAM SKY130 custom-cell fixes

Base: OpenRAM dev `d93bdaa3c61530e1ed9e9f38a8f7904793f71795`.
Apply `sky130-custom-physical-and-pin-types.patch` to that checkout.

1. Deep-N-well moat: SKY130 nwell.5a/7 requires N-well overlap of at least 1.03 µm inside and 0.4 µm outside the deep-N-well edge. The original centered minimum-width N-well path supplied only about 0.42 µm per side. Use a 2.10 µm-wide physical path (1.05 µm per side), without changing the DRC deck.
2. Custom bitcell pin types: order is BL, BR, WL, VPWR, VGND. Correct the directions/types to OUTPUT, OUTPUT, INPUT, POWER, GROUND so the timing graph follows WL to the bitlines rather than treating WL as ground.
3. Custom bitcell storage nets: use Q/Qbar, matching `technology/sky130/sp_lib/sky130_custom_cell.sp`; default Q/Q_bar did not exist and broke delay stimulus generation.

4. Large inverter drive stages: split sizes above 24 into parallel slices with individual body contacts. This preserves the requested aggregate drive size while reducing the diffusion-to-body-contact distance below the 15 µm latch-up limit. Shared M2/M3 input/output buses include widened junctions to avoid narrow notches. The size-128 standalone inverter at the actual DFF row height (7.07 µm) passes DRC/LVS.
5. Custom-cell LVS views: add explicit `u` length/perimeter and `p` area suffixes in four LVS-only cell views. The simulation views use the PDK's micron-valued subcircuit parameters; Netgen compares the extracted SI dimensions. Missing LVS views caused a factor-of-1,000,000 W/L mismatch. No device dimensions are changed.
6. LVS report parsing: detect Netgen's “Netlists match uniquely with property errors” and trailing property-error list, in addition to the older error wording. Connectivity equivalence alone must not pass a dimension mismatch.

The upstream dev changes additionally repair generic array placement/mirroring and Magic script invocation. The source patch does not waive DRC errors, alter the PDK verification rules, blackbox newly generated logic, or force a successful LVS result.

Small 8×16 reproduction: custom cell before moat fix had DRC=4, LVS=0. After the physical fix, `runs/debug_custom_fixed/verification.json` reports DRC=0, LVS=0, with final verification enabled. Full save/analytical Liberty generation succeeds after the pin-type and storage-name fixes (`runs/debug_custom_full`). Target-capacity validation is recorded separately; a small-cell pass alone is not a target-capacity pass.

Final target validation: `64x64_custom_tapped` and `64x128_custom_tapped` both pass full macro DRC=0, LVS=0 with no property errors. GDS and LVS-netlist hashes are recorded in each packaged `verification.json`.
