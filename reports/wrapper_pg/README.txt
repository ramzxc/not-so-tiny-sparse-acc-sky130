Wrapper PG connectivity repair, 2026-11-12

Reproduced against the tap/endcap OpenDB from failed Actions run 43218440940.
OpenROAD: dcf36133a369abc8f3c5e5738cd4d82e4903c0e0 (same CI build).
Before: PSM-0069 for VPWR/VGND; disconnected wrapper rails and tap/endcap cells.
After: check_power_grid passes for both supplies (see local_connectivity.log).

Fix: preserve fixed core and TT stripe positions; add two M3 perimeter links
outside the core at x=1373.35 and 1374.45 um. Materialize the existing left M4
power terminals, then generate M1-M3 and M1-M4 via stacks on existing shapes.
No core GDS, netlist, SRAM, or signal timing ECO changes.
All CI power connectivity, DRC, LVS, XOR and precheck checks remain enabled.
Connectivity passing alone is not a replacement for those physical checks.

Actions run 43222292875 confirmed VPWR/VGND connectivity and routing DRC pass.
The next blocker was Magic stream-out: missing core PR boundary.
scripts/add_core_boundary.py inserts one top-cell 235/4 rectangle matching LEF,
(0,0)-(1367.12,214.88) um. All other GDS bytes are preserved; see
macro/acc_hard_macro/boundary_validation.json. Local Magic 8.3.623 now reads
FIXED_BBOX = 0 0 273424 42976 in its 0.005 um internal units.

Actions run 43223298860 passed boundary extraction but found ICC2 GDS DBU
0.1nm incompatible with Magic read-only macro copying (requires 1nm).
normalize_core_gds_units.py exactly divides all length integers by 10 and
rescales UNITS; all 1,212,987 values divide exactly, with no rounding.
Source SRAM/standard-cell geometry and reference transforms still match.
Local Magic read-only copy into a wrapper now succeeds (297 cells retained).

Actions run 43224191220: PG connectivity and XOR pass (0 differences).
Final DRC: Magic 83 markers / KLayout 14, all M1 spacing at bottom wrapper
rail y=5.44 beside core routing. Core-only full Magic DRC independently = 0.
Reserve only the bottom wrapper row before placement/filler insertion; remove
its preinserted tap/endcap cells. Core instances/GDS are untouched. Generate
bottom VPWR rail centered at y=5.04, giving 0.38um clearance to core metal
(minimum 0.28um), with VGND at original y=2.72. Keep TT M4 stripe positions.
Local regenerated PG still passes VPWR and VGND connectivity checks.

Magic LVS extraction also rejected a 6403-character LEF polygon line and the
virtual OVERLAP layer. Wrap polygon tokens and omit only OVERLAP metadata;
all physical-layer tokens remain identical (lef_validation.json). Magic LEF
read now completes without errors.
