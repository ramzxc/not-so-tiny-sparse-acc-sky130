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
