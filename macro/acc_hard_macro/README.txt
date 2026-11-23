Tiny Tapeout hard macro for the four-lane FP8 accelerator.

ICC2 source: quad_local_fc_50mhz_20261123_155755_x3PhPW, optimized checkpoint, with standard-cell fillers and local route repair.
The wrapper retains the acc_hard_macro interface. All active physical views
derive from the same run. The top cell was renamed consistently, and the
GDS boundary and database units were normalized for the wrapper flow.

Pin mapping: UART RX ui[3], UART TX uo[4], ready uo[2], fault uo[1].
PSRAM-A QPI chip select uio[6], clock uio[3], DQ0–DQ3 on uio[1,2,4,5].
One 512 B SRAM is included in the GDS and netlist.
The macro placement is (5.52, 5.44) um and its size is 1367.12 x 214.88 um.
M4 supply columns interrupted by the SRAM expose edge contacts in the wrapper.
