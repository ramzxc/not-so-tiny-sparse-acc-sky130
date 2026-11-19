# Area tradeoffs after restoring MICRO

The software-unrolling experiment is rolled back. Active RTL matches the saved
pre-experiment source snapshot; UART input, PSRAM instruction/weight reads,
64-bit instruction buffering, DMA, FP8 and the 1 KiB SRAM remain intact. No
synthesis is authorized or run for this rollback. None of the proposals below
has been implemented or measured for area/speed.

Rollback verification: all 12 full EGRU+FC results and cycle/counter measurements
exactly match the saved baseline; four MICRO tests and four UART/PSRAM integration
tests pass. A stale cached integration binary initially used the discarded
protocol; rebuilding resolved it. Both a fresh build and the default build pass.
Evidence: `reports/micro_reduction/rollback.json`.

The discarded experiment preserved numerical outputs but increased program
execution from 21.5–126.2 ms to 73.4–366.7 ms across the same twelve full EGRU+FC
frames at a nominal 50 MHz. Expanded instruction traffic is expensive. Keep
hardware inner loops, not just sparse decisions. See [historical comparison](micro_reduction.md).

| Priority | Candidate | Hardware opportunity | Cost / limitation |
|---|---|---|---|
| 1 | Normalize MICRO to SRAM input and DMA-staged weights | Remove direct/external-input mode branches; narrow SRAM-only input/batch pointers; remove mode registers and mux inputs | All MICRO weights must use a tile buffer. Small or one-use operations can incur extra staging. Ordinary MEM/EXEC can still implement them. Arbitrary networks/batches remain possible within tiling limits. |
| 2 | Move full-tile overlap/layout validation to the program generator | Remove validation states, repeated span checks and dedicated check temporaries where no longer needed | Hardware no longer catches every bad layout before partial execution. Retain physical memory bounds, DMA span checks and error reporting. Requires a reliable program validator and explicit trusted-program contract. |
| 3 | Remove only the B>1 all-zero-column scan | Simplify scan state/selection control, retaining batch loops and per-sample zero skipping | DMA loads a column even when all samples are zero. No numerical change for valid programs; more PSRAM traffic in very sparse batches. Savings may be small because scan logic already shares much of the controller. |
| 4 | Require packed weight tiles (stride = 2*groups) | Remove the 24-bit programmable stride register and stride-selection logic | Software must repack/possibly duplicate tiled weights; PSRAM layout becomes less flexible. Current Bishop images use stride 24 for groups 8/4, so they must change. Current groups 12 and FC groups 1 already use packed strides. |

Recommended order: first examine mode normalization while preserving hardware
column/group/batch loops; then consider moving validation if trusted generated
programs are acceptable. Evaluate each change separately using the same complete
network, not only the MAC. These are likely opportunities based on RTL structure,
not predicted percentages; synthesis may already optimize some apparent state.

For the current full-network generator, MICRO inputs are SRAM and all runs are
auto-DMA. Therefore the first proposal aligns with this workload, while limiting
the generic hardware interface. It is not an EGRU-specific operation restriction:
other networks still compile into the same generic arithmetic and staged tiles.
Its exact performance equivalence must be checked after implementation.

Avoid first: removing all MICRO loops again; reducing the instruction buffer
from four words when fetch bandwidth is already costly; dropping batch support;
shrinking the 1 KiB working SRAM or changing FP8 precision. These carry substantial
traffic, capability, working-set or numerical costs relative to the current goal.
Do not assume that simply storing aligned addresses without the low zero bit
saves a physical flop: synthesis may already prove that bit constant.
