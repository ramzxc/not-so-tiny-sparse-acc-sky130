# Experimental buffered SRAM output

This candidate keeps the 64-bit by 128-word memory and the existing read/write
protocol. It adds a non-inverting `pbuf(size=8)` immediately after each sense
amplifier, including the spare column. The buffer fits within the four-column
pitch. It does not add a pipeline stage.

The output stage is placed beside the sense amplifier. Its well alignment and
local power connections are physical geometry, included in GDS and transistor
LVS. The array uses M3 power rails. No LVS exclusions or DRC waivers are added.

Build in a new directory with the locally patched OpenRAM baseline:

```sh
python3 build.py /path/to/new/candidate
```

The source hashes prevent accidentally applying the patch to a different
baseline. The released SRAM views and core macro are not overwritten.

This is not a release or a characterized timing model. Validate the complete
array, extracted timing, antenna, and core integration before using it.

The original 27.56 fF Liberty `max_capacitance` is the largest load in OpenRAM's
generated characterization grid, not a measured transistor drive limit.
Changing that number alone is not a timing fix. The output-stage change needs
new timing characterization over the intended output loads and PVT corners.
