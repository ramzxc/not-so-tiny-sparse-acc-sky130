> **Historical FP16 / 512 B results.** Current RTL is FP8 E4M3FN / 1 KiB.
> These numerical timing, area and workload estimates do not characterize the new build.

# Burst DMA throughput experiment

The burst-only batch=1 DMA/MICRO snapshot measured below was not ready to claim sustained Bishop
processing at 50 MHz, 20 ms arrivals and a 100 ms per-input deadline. Component
cycles were measured in RTL. Full EGRU execution, PC input delivery, state
spilling and deadline behavior were **not** simulated end-to-end.

## Reproduce

With the existing cocotb environment activated:

```sh
make -C test -f Makefile.perf
python3 -m cocotb_tools.check_results /tmp/acc-throughput-hw/results.xml
python3 scripts/evaluate_bishop_throughput.py
```

`test_throughput.py` uses real UART, DMA, MICRO, FP16 arithmetic, OpenRAM functional
SRAM and QSPI NOR models. Only external Flash is preloaded. Testbench counters
measure busy cycles independently of host setup. The UART divider is the hardware
value 87. Simulation uses a 100 ns clock for functional evaluation; all time
estimates below convert measured cycles to 50 MHz, without claiming physical timing.
No core RTL was changed for this experiment.

Local artifacts (ignored under the repository's existing reports convention):

- `reports/throughput/measurements.json`: measured component and host cycles.
- `reports/throughput/bishop_estimate.json`: workload assumptions, RTL SHA256,
  full-test input activity statistics, historical hidden event counts and estimates.
- `reports/throughput/*50mhz.rpt`: synthesis timing/area excerpts.

## Measured component costs

| Operation | Busy cycles | At 50 MHz |
| --- | ---: | ---: |
| DMA 4 B | 150 | 3.00 us |
| DMA 64 B | 630 | 12.60 us |
| DMA 128 B | 1,142 | 22.84 us |
| DMA 256 B | 2,166 | 43.32 us |
| DMA 512 B | 4,214 | 84.28 us |
| MICRO 64 MAC, SRAM input/weights | 1,004 | 20.08 us |
| MICRO 128 MAC, two active columns | 1,998 | 39.96 us |

DMA sizes fit `118 + 8 * bytes` cycles. Single-active-column MICRO fits
`12 + 15.5 * MACs`. The 512 B DMA test measures copy only: it fills all SRAM,
so it is not a simultaneous input/weight/output tile layout.

Without cache hits or DMA/compute overlap, each FP16 MAC costs asymptotically
`2 * 8 + 15.5 = 31.5` cycles for weight transfer plus computation. This optimistic
model removes header/setup overhead and other EGRU operations.

| Dataset | Optimistic mean time | Minimum MHz for 20 ms | MHz for 16 ms |
| --- | ---: | ---: | ---: |
| bishop_0 | 22.57 ms | 56.41 | 70.52 |
| bishop_1 | 23.88 ms | 59.69 | 74.61 |
| bishop_2 | 20.89 ms | 52.23 | 65.28 |
| bishop_3 | 20.54 ms | 51.34 | 64.18 |

These are estimates using all test inputs and **historical fixed16** hidden event
means. The chip's FP16/hard activation may produce different events. Previous-step
activity/trial boundaries are not reconstructed; event count is a workload proxy.
They are not measured network latencies or a deadline-miss trace. The 16 ms column
reserves 20% of the arrival interval before adding omitted work; it is not a
recommended or timing-validated clock.

## Actual host-driven tile

One valid layout is input at 0, 128 B weights at 4, 128 B outputs at 384.
A measured tile copies weights then updates 64 outputs for one active input.
It uses 18 UART words, including three words for host SYNC/retirement observation;
there is no intermediate SYNC between DMA and MICRO. It takes **45,494 cycles
(909.88 us)**, while the DMA and MICRO busy counters sum to only **2,146 cycles
(42.92 us)**. Input delivery, output initialization/spill and gate updates are
excluded. This is one concrete simple schedule, not a minimum over all schedules.

Repeating that schedule for the three 256-wide input projections alone gives
`12 tiles * active_inputs * 909.88 us`, approximately **263..277 ms/step** on
Bishop test means, before recurrent work. Setup/transport automation is therefore
needed even independently of uncertainty about hidden activity.

At 50 MHz, divider 87 gives 574,713 baud. Eighteen 16-bit words require at least
`18 * 20 * 87 = 31,320` cycles (626.4 us) for 8N1 transmission alone. Packing four
words into a 64-bit register may reduce credit/idle gaps, but still transmits
80 wire bits per packet. It cannot eliminate this wire-time cost. A reusable
DMA-to-MICRO tile command with retained parameters can eliminate repeated words;
a wider receive buffer alone cannot.

## Physical clock experiment

A local Design Compiler experiment synthesized the current core at 20 ns using
TT 1.8 V/25 C libraries, the existing wire-load model and the existing SRAM model.
The worst register-to-register setup slack was about **+0.01 ns**, in the SRAM
accumulation path (`itf/state_reg` to `itf/write_word_reg`). SRAM-output capture
reported about +8.51 ns. Total mapped cell area including SRAM was 163,243 um2;
this is not an isolated area delta for the burst change.

Whole-design WNS was **-6.03 ns**. The existing absolute 20 ns IO delays were
retained, leaving no internal output budget at a 20 ns period. This is neither
an IO timing pass nor proof of a physical 50 MHz limit: actual board/Flash
constraints and post-route, appropriate-corner timing are still required. The
near-zero internal slack also gives no signoff margin at 50 MHz.

To repeat in a new output directory with the repository's local DC setup:

```sh
ACC_MANUAL_OUT=/tmp/acc-sta50-new dc_shell -f scripts/measure_core_timing.tcl
```

## Next changes to evaluate

1. Retain DMA/MICRO parameters and automate repeated tile dispatch, reducing
   UART words per useful MAC. A four-word packet alone is insufficient.
2. Reduce per-vector MICRO dispatch and SRAM accumulation cycles. For bishop_1's
   historical mean, with unchanged DMA slope, compute must fall from 15.5 to
   below about 10.4 cycles/MAC just to fit 20 ms before other work. Reserving 20%
   of that interval would require below about 5.1 cycles/MAC, or a combination of
   faster DMA, weight reuse, and compute improvements.
3. Define a workable full-model state/spill and host data/readback path. The
   current 512 B SRAM does not hold even the 1 KB h/y state pair.
4. Measure a complete numerical execution schedule and replay 20 ms arrivals,
   checking every result deadline at arrival+100 ms. No such deadline guarantee
   follows from these component or historical-mean measurements.

## Automatic MICRO DMA update (batch support included)

The new RUN bit 1 moves repeated weight-copy dispatch into MICRO. BUFFER and
STRIDE settings are reusable; there is no new control module or instruction RAM.
It supports both single inputs and packed batches, including all-zero-column
DMA suppression. The prior measurements above remain a historical baseline.

Reproduce the new synthetic active-input measurements with:

```sh
make -C test -f Makefile.perf BUILD=/tmp/acc-auto-dma-perf COCOTB_TEST_MODULES=test_auto_dma_performance
```

At an assumed 50 MHz, UART divider 87:

| Batch | Columns | Output groups | MACs | MICRO including DMA | Host setup + RUN + SYNC |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 32 | 64 | 43.76 us | 1.112 ms |
| 1 | 16 | 32 | 1,024 | 688.80 us | 1.700 ms |
| 1 | 64 | 32 | 4,096 | 2.753 ms | 3.764 ms |
| 1 | 16 | 16 | 512 | 365.92 us | 1.377 ms |
| 4 | 16 | 16 | 2,048 | 920.48 us | 1.931 ms |

Input delivery and output initialization/spilling are excluded in both this
experiment and the old host-tile comparison. Weights are copied for every column;
these rows use synthetic nonzero inputs to measure control cost, not network
accuracy or real sparsity. MICRO busy now includes time spent waiting for DMA;
do not add its DMA counter a second time.

For 64 columns and 64 outputs, the old 64-MAC host schedule repeated 64 times
would take 58.23 ms; one automatic tile takes 3.764 ms including all configuration
and SYNC. This illustrates command-overhead removal, not a complete-model speedup.
The new one-column run has more initial configuration than the old schedule, so
it is deliberately not optimized for standalone tiny copies.

The local 20 ns TT synthesis comparison increased total mapped cell area from
163,243 to 167,478 um2 (+2.59% including the unchanged SRAM, +6.45% excluding it).
Sequential cells increased from 849 to 899. This includes configurable stride,
complete batch-span overlap checks and batch scan control. No data FIFO, multiplier,
or SRAM was added. Synthesis remapping is included in this area comparison.

Internal worst setup slack still rounds to +0.00 ns; whole-design WNS is -6.03 ns
under the retained absolute 20 ns IO constraints. It is not a post-route or board
50 MHz timing pass. Full-network working storage, gate/state operations, actual
activity and deadline behavior still require a complete schedule and validation.
Artifacts are under the ignored local `reports/auto_dma/` directory.

## Bishop re-evaluation with auto DMA (2026-11-19)

**The current retained-command tile schedule does not sustain 20 ms inputs at
50 MHz. Even its input projection alone exceeds the budget.** This is a timing
estimate calibrated against RTL, not a full-network numerical execution or a
claim that every possible schedule must fail.

The new performance test executes 48 tiles through UART, Flash and SRAM using
batch 1, 2 and 4. It checks successful completion and the number of Flash read
transactions. Inputs use zero/nonzero masks (nonzeros replaced with FP16 one);
weights are timing fixtures, not trained weights. Numerical accuracy is outside
this experiment. Thirty-nine cases calibrate the model; nine held-out cases,
including actual Bishop masks, match exactly, with zero cycle error. This does
not prove every untested tile size, but provides independent checks of the model.

For a tile, let C be columns, P=ceil(C/2), G output groups, B batch size,
U columns active in any sample, A total active scalar inputs, and S the number
of scalar checks before finding the first active sample in each column (B for
an all-zero column). Measured MICRO cycles, including DMA, are:

```
B=1: G + 11P + 3C + 126U + 63UG
B>1: G + P + 2C + 11S + 126U + 43UG + 12UGB + 20AG
```

With retained configuration and UART divider 87, the measured 11-word
input/weight/count/RUN/SYNC transaction takes
`max(27805, MICRO_cycles + 22753)` clocks. This matches all 48 measured cases.
It includes the current Host driver's pacing; it is not a fundamental UART
bandwidth limit. At 50 MHz the UART baud rate is approximately 574,713.

The evaluator applies this model to every complete batch in all four Bishop
test sets, for the D-by-768 input projection. It sweeps even input chunk sizes
plus the full dimension. Each candidate uses a fixed chunk size and the largest
output group count satisfying `4*ceil(C/2)*B + 4G + 4GB <= 512` bytes for input,
weight buffer and output. It selects the lowest mean host cost within that
schedule family. This is not an exhaustive search of all possible schedules.

At 50 MHz, ranges across bishop_0 through bishop_3 are:

| Batch | Input-only MICRO mean per input | With host commands, mean per input | Wait to collect batch |
| ---: | ---: | ---: | ---: |
| 1 | 12.57–13.27 ms | 21.68–22.37 ms | 0 ms |
| 2 | 15.59–16.61 ms | 27.88–29.58 ms | up to 20 ms |
| 4 | 15.72–16.67 ms | 37.61–38.52 ms | up to 60 ms |

Batch 1 selects C=100/G=39 with 20 tiles per input. Batch 2 selects C=62/G=22
for the first three datasets (54 tiles/batch) and C=64/G=21 for bishop_3
(57 tiles/batch). Batch 4 selects C=24/G=16 (192 tiles/batch). Weight reuse
across a batch is offset here by SRAM capacity, more output tiles, input rereads
and union sparsity. This does not mean batch support should be removed.

These costs still **omit input transfer/packing, partial-sum initialization and
spill/readback, tile reconfiguration, recurrent projection, activations, state
updates and the head**. Omitted costs are treated as zero; the schedule is not
yet a complete executable model. Future input projections can be batched, but
recurrent timesteps depend on preceding state and cannot simply be treated as
independent samples.

The queue model assumes uninterrupted 20 ms arrivals, dispatches each batch
when its final sample arrives, and returns all its results on completion. Even
with only the modeled input projection, all selected schedules accumulate
backlog and miss arrival+100 ms deadlines. Actual trial gaps are unknown, so
these are continuous-load results, not measured session latencies. Batch 4 also
has only 40 ms left for its first sample after collecting the batch, compared
with modeled mean input-projection service of 150–154 ms per batch.

For batch 1 the input projection alone would need about 54.2–55.9 MHz to meet
the *mean* throughput target with unchanged cycle counts. This is not a usable
full-EGRU clock requirement, and supplies no deadline or timing margin. Current
RTL hashes match the previous 50 MHz synthesis: internal slack is approximately
zero and whole-design IO timing still fails the retained constraints. No new
physical timing pass is claimed.

Recommended next experiments, ordered to avoid committing area prematurely:

1. Measure less host pacing/fewer tile synchronizations and higher UART baud
   using the same schedule. Batch 1 currently spends about 9.1 ms/input beyond
   MICRO busy time; quantify recoverable cost before adding an instruction FIFO.
2. Implement the complete input/state/partial-sum transfer schedule and a
   chip-matched numerical reference. Replay arrivals and check each deadline;
   input-only timing is insufficient to certify EGRU.
3. Profile repeated MICRO command dispatch and SRAM accumulation, then compare
   small execution-path changes by cycle savings and mapped area. Command
   transport improvements alone do not remove the 12.6–13.3 ms input-only core
   cost or the still-unmeasured recurrent/state cost.

Reproduce using `scripts/prepare_bishop_perf.py`, `test/test_bishop_performance.py`
and `scripts/evaluate_bishop_auto_dma.py`; commands are in `test/README.md`.
Local raw measurements, passing test XML, model coefficients, source hashes,
per-dataset schedules and deadline counts are in `reports/bishop_auto_dma/`.

## Host-only optimization, with unchanged results (2026-11-19)

This experiment changes neither RTL nor clock/baud settings, arithmetic order,
FP16 precision, sparse semantics, batch support or SRAM capacity. All RTL hashes
match the previous synthesis and timing calibration. No new hardware area or
physical-clock capability is claimed. Simulation cycles are converted to an
assumed 50 MHz; this is not a new 50 MHz physical timing test.

Three software changes are implemented:

1. Stream the next retained-configuration MICRO command sequence while the
   preceding RUN executes. Existing blocking dispatch and UART credits preserve
   order. Remove intermediate host SYNC/NOP fences, but retain a final fence.
2. At the final fence, send SYNC and one NOP and wait for the following READY.
   Retain that credit for a real instruction instead of transmitting a second
   NOP. Do not remove internal operand/result dependency SYNC instructions.
3. Omit a redundant ADDR high word when its value is known. In a chain of valid,
   nonempty auto-DMA runs with SRAM inputs, the previous run leaves this high
   word zero. Other operations require conservative invalidation; Flash-input
   runs do not imply the same invariant. Within a configuration sequence, the
   helper also knows the high word it just set.

`scripts/micro_schedule.py` emits reusable instruction words, while the test
Host implements the shorter fence. This is not yet a complete board driver or
network compiler. It does not supply missing partial-sum/state transfer paths.

Nineteen finite-data chains compare the baseline, streaming and compact modes;
three more mix short and long runs to check backpressure transitions. All 22
match **output bits, MICRO/DMA cycles and Flash read counts**. Outputs also match
an independent exactly representable arithmetic oracle. A separate test checks
low Flash addresses and conservative Flash-input handling. All 12 existing serial
integration tests pass. SRAM is observed read-only immediately at fence return;
input and output initialization use actual Flash DMA, not SRAM backdoor writes.

At UART divider 87, for N consecutive runs, the measured savings are:

```
intermediate host fences:  (N - 1) * 7581 cycles
known high-address word:  (N - 1) * 2527 cycles
shorter final fence:                  1748 cycles
```

The first compact run is conservative. The formulas are determined from two
chain-length cases and match the other 20 cases, including mixed durations.
The new benchmark begins after SYNC's eight-cycle observation pad, so its
baseline is eight clocks per tile shorter than the previous benchmark. The
comparison accounts for that small measurement-boundary difference explicitly;
it is not counted as an optimization.

Applying these measured savings to the same Bishop input-projection schedule,
then repeating the same legal tile-size sweep, gives:

| Batch | Baseline mean per input | Optimized mean per input | Reduction |
| ---: | ---: | ---: | ---: |
| 1 | 21.67–22.36 ms | 17.80–18.49 ms | 17.3–17.9% |
| 2 | 27.87–29.58 ms | 22.50–23.90 ms | 19.0–19.3% |
| 4 | 37.60–38.51 ms | 27.94–28.85 ms | 25.1–25.7% |

The best geometries remain unchanged except bishop_3 batch 2, which improves
by about 0.0003 ms/input at C=50/G=26. In batch 1, removal of intermediate fences
saves 2.916 ms/input and address elision another 0.960 ms/input. Core execution
is unchanged. The 20 ms mean budget now leaves only 1.51–2.20 ms/input for all
omitted work: recurrent projection, gates, head, state movement, input delivery,
partial-sum initialization/spills/readback and tile reconfiguration.

The estimates still assume that commands can be streamed across the omitted
tile transitions. A future actual transfer schedule may need additional address
restores or observation boundaries. Those costs must be included before claiming
full-network performance; neither this optimized estimate nor the earlier one
is a complete executable Bishop schedule.

### Deadline result and remaining performance requirement

**Mean input-projection throughput is not sufficient to meet arrival+100 ms.**
Actual masks contain sustained periods of higher activity. Under continuous
20 ms arrivals, batch-1 input-only latency reaches 1.53–1.87 seconds in this
queue model, even though the overall mean service is below 20 ms. These are
modeled latencies from timing-calibrated input projection, not measured board
or complete-network result latency.

Trial offsets are present but actual timestamps and gaps are absent. A favorable
check resets the queue at every trial boundary; it still misses 100 ms:

| Dataset | Optimized input-only misses, empty queue per trial | Core-only misses, host cost zero | Core-only worst latency |
| --- | ---: | ---: | ---: |
| bishop_0 | 4,051 / 31,323 | 284 | 319.9 ms |
| bishop_1 | 2,676 / 24,966 | 462 | 581.8 ms |
| bishop_2 | 2,645 / 25,539 | 558 | 387.4 ms |
| bishop_3 | 3,128 / 21,305 | 572 | 409.2 ms |

Thus even deleting every host-command cycle would not meet these trace deadlines
with the selected current core schedules. More improvement than command transport
alone is needed. This does not prove that an area/precision tradeoff is necessary:
equivalent RTL scheduling or a different legal execution schedule may still help.

Uniformly scaling each optimized input-only service time down until every
continuous-trace deadline passes requires a further **25.8–34.3% time reduction**
(about 1.35–1.52x service-rate improvement). This is a sensitivity experiment,
not a guaranteed target for any particular optimization or for unseen inputs.
It still excludes the rest of the network.

For a separate indication of the full-network mean gap, using historical fixed16
hidden event activity and only the optimistic recurrent slope of 31.5 cycles/MAC
adds 8.22–12.21 ms/input. Combined with optimized input projection, this gives
26.71–30.00 ms/input, before recurrent headers/host overhead, gates/head and state
movement. That proxy requires 25.1–33.3% further time reduction just to reach
20 ms on average, or 40.1–46.7% to target 16 ms. Historical fixed16 activity is
not a current FP16/hard-activation trace; these figures are a sensitivity proxy,
not a measured full-network runtime or a lower bound on every implementation.

The next substantive target is core execution/accumulation cost and a complete
numerically checked state/transfer schedule. A larger FIFO, faster UART or more
host buffering alone cannot be certified as sufficient by these results.

Reproduction commands are in `test/README.md`. Raw measurements, passing XML,
per-dataset before/after estimates, deadline sensitivities and unchanged RTL
hashes are stored in the ignored local `reports/stream/` directory.
