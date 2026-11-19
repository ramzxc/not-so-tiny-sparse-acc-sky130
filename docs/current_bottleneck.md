# Current buffered SRAM: complete-network bottlenecks

This report records the pre-alignment layout. The applied software change and current measurements are in [weight_alignment.md](weight_alignment.md); baseline raw profiles are preserved under `reports/weight_alignment/before`.

Selected high-activity windows, not workload averages. Exclusive categories add exactly; occupancy counters overlap. Counterfactual subtraction is not an implemented speedup. 50MHz cycles, 25MHz QPI SCK; not physical timing signoff.

All 12 adjacent Bishop frames pass full state/FC/PSRAM comparisons. Only passive testbench counters were extended; functional RTL and synthesis were untouched.

Representative: bishop_2, step 24067. Program 77.70384 ms; UART front 4.74728 ms; completion credit 0.01654 ms. Output store is already in program time.

| Exclusive category | ms at 50 MHz | Program share |
|---|---:|---:|
| DMA external transfer and handoff | 29.2904 | 37.69% |
| DMA SRAM read/commit | 1.8298 | 2.35% |
| SRAM read-add-write | 8.9039 | 11.46% |
| Other SRAM access | 3.6413 | 4.69% |
| Other external access | 0.0006 | 0.00% |
| EXEC arithmetic/activation | 9.1037 | 11.72% |
| MICRO control/handoff | 20.8183 | 26.79% |
| Exposed instruction fetch | 3.6651 | 4.72% |
| Dispatch/drain | 0.4507 | 0.58% |

DMA dominates with 31.1203 ms; MICRO control/handoff contributes 20.8183 ms. DMA SRAM includes partial-row preservation reads as well as commits. Its other bucket includes external transfer and controller handoff, not exclusively PSRAM wire time.

## External data traffic

Data requests: 27,802; payload: 150,196 bytes; average 5.402 bytes/request. All but one request are reads; the last writes the two FC bytes. Row-bounded bursts are already implemented.

QPI data-controller active: 27.02860 ms, of which 12.01568 ms transfers payload and 15.01292 ms is command/address/dummy/select/finish/recovery. These are a decomposition of bus activity, not extra costs to add to the table.

## MICRO exclusive control states

| State | ms excluding active DMA/memory/EXEC |
|---|---:|
| W_SYNC | 5.9359 |
| A_SYNC | 4.4519 |
| W_DATA | 1.4840 |
| EXEC | 1.4840 |
| EXEC_SYNC | 1.4840 |
| STORE | 1.4840 |
| I_SYNC | 0.8141 |
| COLUMN_CHECK | 0.4058 |
| COLUMN_END | 0.4058 |
| D_NEXT | 0.4058 |
| I_DATA | 0.2035 |
| I_LO | 0.2035 |
| I_HI | 0.2035 |
| I_MEM | 0.2035 |
| D_VALIDATE_INPUT | 0.2035 |
| D_SRC_LO | 0.1777 |
| D_SRC_HI | 0.1777 |
| D_SOURCE | 0.1777 |
| D_DST_LO | 0.1777 |
| D_DST_HI | 0.1777 |
| D_DEST | 0.1777 |
| D_RUN | 0.1777 |
| D_WAIT | 0.1777 |
| B_VALIDATE | 0.0237 |

For 74,199 two-lane accumulate operations, W_SYNC costs four exclusive cycles each; A_SYNC three each. Together these account for 10.38786 ms beyond active memory/EXEC time. W_DATA, EXEC, EXEC_SYNC and STORE add one exclusive cycle each (5.93592 ms together). These are command/handshake and dependency costs, not proven removable idle cycles. Inspect DATA readiness and operand/result validity before any shortcut.

## Network phases

| Phase | ms |
|---|---:|
| Initialization | 0.0918 |
| Bias setup | 0.2332 |
| Input u/r | 20.8131 |
| Recurrent | 39.9366 |
| Gates | 0.8597 |
| Input z | 12.1177 |
| State update | 3.3459 |
| FC | 0.3012 |
| Fence | 0.0013 |
| Output store | 0.0033 |

## Deadline sensitivity: all four three-frame windows

Keep UART and every other category unchanged; subtract the specified fraction from measured service times and repeat FIFO queue calculation. This is an accounting sensitivity, not a simulated modified design.

| Category | Worst latency if cost halved (ms) | Worst latency if cost zero (ms) |
|---|---:|---:|
| DMA | 139.174 | 98.915 |
| MICRO control | 151.746 | 124.057 |
| EXEC | 167.503 | 155.572 |
| SRAM accumulation | 167.803 | 156.172 |
| Instruction fetch | 173.936 | 168.439 |

The hardest window requires 219.43386 ms of current service across three arrivals at 0/20/40 ms. To finish the third by 140 ms requires at least 36.20% total service reduction in that window (1.567× uniform service rate). Excluding UART, initialization and output even optimistically, 204.85698 ms must fall to 140 ms: 31.66% reduction. These are necessary window-specific targets, not full-trace guarantees.

## Next investigations, ordered for area

1. Software SRAM layout: align the weight scratch base to eight bytes. It is currently 956, which splits 16-byte tiles into 4+8+4 and 24-byte tiles into 4+8+8+4. The representative frame has 8,800 eligible tiles: one fewer transaction each saves 4.752 ms of protocol cycles, before changed SRAM/handshake costs. A simple base edit overlaps accumulators. The current generator reserves eight bytes each for temp_a/temp_b although each pair is consumed within one state-update iteration; verify pair reuse, then repack scratch/accumulators. This candidate changes software layout, not SRAM capacity or arithmetic order. Not yet implemented.
2. DATA/MICRO handoff: investigate the W_SYNC/A_SYNC residual cycles, and compact input-load/DMA setup where invariants permit. Preserve batch support and all memory/execution fences until dependencies are explicitly satisfied. No new cache or MAC needed merely to investigate.
3. SRAM accumulation path: six cycles per two-byte read-add-write. Reducing repeated row transfers or retaining accumulators could help, but buffers/registers and rounding order become explicit tradeoffs. Measure after the software/handshake candidates.
4. Larger bursts, wider compute or more buffering are later tradeoffs. Halving DMA alone still gives a 139.174 ms worst selected response. Eliminating instruction-fetch cost alone leaves 168.439 ms; instruction caching cannot solve this by itself.

Reproduce: run `scripts/evaluate_stream_deadline.py` with the profiled current binary, then `python3 scripts/summarize_current_bottleneck.py`. Raw evidence: `reports/stream_deadline/bottleneck.json`.
