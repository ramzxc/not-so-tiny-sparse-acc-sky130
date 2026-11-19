# Experiment: UART ingestion without a PC backlog

Baseline checkpoint: `6f7a129`, branch `checkpoint/pc-buffered-50mhz`.
Experiment branch: `experiment/no-pc-buffer`. The checkpoint contains the prior
working tree's source, tests, documentation and selected SRAM deliverables.
Ignored reports/physical-run directories remain local, not part of that commit.
No synthesis or PNR was run for this experiment.

`program_ctrl.v` moved from `src/rtl/core/` to `src/rtl/`: it is the external
program/input frontend, whereas MICRO manages compute loops and sparse decisions.
The move is functional-neutral. The changes below are separate experimental
functionality and do add control logic.

## Outcome

**Receiving fixed 20 ms input frames without host-side backlog is demonstrated
for finite RTL tests. Continuous bounded-latency real time is not established.**
The new receiver stores incoming frames in external PSRAM while the network
executes. This moves buffering to memory controlled by the chip; it does not
eliminate buffering or fix a sustained compute deficit.

50 MHz core, UART divider 87 (574713 baud), QSPI 25 MHz. Two complete-network
fixtures were each repeated eight times. Frames start every 1,000,000 core cycles
(20 ms); the UART producer never waits for READY after stream enable. Eight full
frames arrived and completed in each test, with zero mismatches in stored input,
256 c states, 256 y states, two FC values, and PSRAM result output.

| Repeated fixture | Maximum queued frames | Response latency | >100 ms responses |
|---|---:|---:|---:|
| Bishop 2 step 100 | 1 | 16.986 ms, each frame | 0/8 |
| Bishop 2 step 24067 | 6 | 74.496 → 433.079 ms | 7/8 |

The slow workload completes frames approximately every 71.219 ms after the
producer stops competing for the bus. The fast workload's completion interval
is 20 ms because it waits for the next arrival; that is not its service time.
Timing is derived from RTL clock cycles, not measured board timing.

These repeat *warm-started* fixtures: programs reload the reference recurrent
state each time. They validate concurrent transport plus full computation, not a
live recurrent trajectory. The smaller queue test uses changing input values to
check order across wraparound. Output is checked at each completion before the
next program can overwrite the output location. There is no output-history ring.

The prior whole-trace model's program means alone are 23.28–25.93 ms, already
above 20 ms. Overlapping UART removes its serial contribution from steady demand
but adds PSRAM queue traffic. Even an ideal zero-cost input queue would still
need about 1.16–1.30x average program throughput, plus margin, for those traces.
No modified whole-trace timing model is claimed. Larger input storage cannot
make the average service deficit or 100 ms deadline disappear.

## Hardware and protocol

- `uart_psram_queue.v` has a 16-bit ingress holding register, a 16-bit replay
  register, slot/index counters and two small state machines. It adds no SRAM
  macro or large on-chip payload FIFO. There are about 110 declared state bits
  at the default slot count, plus two bits in the extra transaction arbiter;
  this is not a synthesized cell-area estimate.
- Reserve PSRAM A addresses `0x400000..0x7fffff` exclusively for the queue.
  16,384 slots × 256 bytes = 4 MiB. Existing 1 KiB SRAM remains working storage.
  Unused padding in slots is a deliberate simplicity/capacity tradeoff.
- Instructions, weights and program output must stay below `0x400000` in this
  mode. The experiment does not enforce that reservation against arbitrary core
  instructions; software/board image preparation must enforce it.
- Use legacy `F100` plus its five configuration words, obeying UART credits.
  After configuration has completed, send `F400` with a credit. `uo[2]` goes high
  to indicate raw stream mode. This mode requires 1–256 input bytes per frame.
  Larger inputs and input-free programs retain the legacy protocol.
- In raw mode send exactly `ceil(input_bytes/2)` little-endian payload words per
  frame, padding the final odd byte. Do not send F200 headers or wait for READY.
  Payload values such as F100/F400 are data, not interpreted commands. Reset is
  required to exit raw mode/reconfigure it. Source data is already frame-ready;
  host-side sample accumulation is outside this transport experiment.
- UART serial reception still uses the existing synchronizer/framing detector.
  An overrun or full ring sets sticky error on `uo[1]`; it does not silently
  overwrite old frames. Reset clears queue ownership and returns legacy mode.
  Raw mode has no CRC/sequence resynchronization; link errors are not repaired.
- Queue writes/readback get transaction-boundary priority over the combined core
  bus. The same QSPI controller performs all transfers. No active burst is
  interrupted. The existing arbiter is reused with optional writes on its second
  requester, so owner state is not duplicated by a separate custom mux.
- A frame becomes visible only when all its words have committed to PSRAM. It is
  replayed as F200 + words into the unchanged frontend, then its slot is released
  after its last input word has been delivered. The current frame can then execute
  entirely from SRAM, while subsequent frames arrive into the PSRAM ring.

## Verification and reproduction

1. Legacy cocotb stream suite: 4/4 pass, including generic batch cases and reset.
2. New queue suite: 3/3 pass. Four-slot wraparound/order, incomplete frame withheld,
   odd-byte padding, deliberate overflow (full count exactly four), sticky error,
   and reset recovery. This uses a faster UART test setting to stress arbitration.
3. Arbiter randomized ownership tests: pass with FETCH_WRITES=0 and 1.
4. Full EGRU+FC fixed-rate tests: 2 × 8 frames pass, above. Existing full-network
   fixtures are required; no test data is regenerated or numerically changed.
5. QSPI sample-phase RTL remains unchanged from the checkpoint.

Commands are in `test/README.md` and `test/Makefile.no_pc`. Numerical results and
logs are saved in `reports/no_pc_buffer/`; `scripts/run_no_pc_network.py` produces
network summaries, including per-frame response times and deadline misses.

The prior physical-fit result does not apply to this added logic. Next work,
if retaining this branch, is to reduce compute service demand, validate continuous
recurrent state carry and test real UART/QSPI timing; request synthesis separately
before judging whether the added logic still fits 8×2 tiles.
