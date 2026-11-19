# SKY130 demo board + QSPI Pmod external timing review

2026-11-19. Scope: not-so-tiny only; core 50 MHz, QSPI 25 MHz, UART divider 87.
User selected the basic demo board + QSPI Pmod. Reference schematics are current
ETR DBv3 and mole99 QSPI Pmod, PSRAM A APS6404L-3SQR-SN, 3.3 V, CK jumper open.
Physical board revision and loaded waveform are not measured.

**Conclusion: frequency limits alone do not establish correct reads. The original
read sampling failed a plausible external-delay scenario. Sampling one core
cycle later passes the directed comparison without increasing transaction time.**
The sampling change is now applied to `src/rtl/qspi_ctrl.v`. The original
comparison remains frozen in `reports/board_timing/experiment/`.
No synthesis, PNR, or new post-route STA was run for this review.

## Sources and limits

- [Tiny Tapeout GPIO specification](https://tinytapeout.com/specs/gpio/): input
  rating 66 MHz, output rating 33 MHz. The output toggle/square-wave interpretation
  is explicitly ambiguous; 32 MHz QSPI has been demonstrated. 50 MHz input and
  25 MHz QSPI are therefore reasonable targets, not board timing guarantees.
  TT3.5 measured round-trip delay reached 20 ns on one die near 22 C; this is
  neither a bound for this shuttle nor separate 10 ns input/output specifications.
- [ETR board](https://tinytapeout.com/specs/pcb-etr/) and
  [schematic](https://github.com/TinyTapeout/tt-demo-pcb/blob/main/doc/tt-etr-dbv3.pdf):
  reference RP2350 board. The exact generated clock frequency/duty/jitter must be
  checked on the configured board; setting project metadata does not configure it.
- [QSPI Pmod](https://github.com/mole99/qspi-pmod): shared Flash + two PSRAMs,
  optional CK jumper adds 22 pF to SCK. Pin assignments match the current wrapper:
  uio0 inactive Flash CS, uio1/2/4/5 DQ, uio3 SCK, uio6 RAM A CS, uio7 inactive RAM B CS.
- [AP Memory datasheet rev 2.3, linked by Pmod schematic](https://www.mouser.com/datasheet/2/1127/APM_PSRAM_QSPI_APS6404L_3SQR_v2_3_PKG-1954826.pdf),
  pp. 19, 20, 23: QPI 0Bh read limit 66 MHz; output delay 2–5.5 ns;
  output hold from falling edge 1.5 ns; input setup/hold 2/2 ns;
  CS setup/hold 2.5/3 ns; CS recovery 18 ns; standard-grade CS-low limit 8 us.
  Specified system load is 15 pF and clock rise/fall maximum 1.5 ns.
  Shared device/board/probe capacitance must be accounted for before relying on
  the 5.5 ns maximum. MCU high-Z does not remove its input capacitance.

Downloaded schematics and source manifest: `reports/board_timing/sources/`.
The AP Memory direct URL returned HTML; it is explicitly marked as such, not used
as a PDF. Published pin measurements do not replace pad/mux PVT timing libraries.

## Read timing calculation

RTL toggles SCK on each core rising edge. PSRAM launches each nibble after its
SCK falling edge; the original RTL captured on the next core edge, which also launches
SCK rising. Available time is **20 ns**, not the 40 ns SCK period.

Required time includes core clock-to-SCK output, outgoing TT mux/pad/board delay,
PSRAM clock-to-data, returning board/pad/mux delay, core input route, setup and
clock uncertainty. Using the reference 20 ns round-trip plus 5.5 ns PSRAM output
already gives **25.5 ns**, before any additional margin. The 20 ns measurement is
used only to construct a sensitivity scenario, not asserted as this board's delay.

The applied change captures on the following core edge, which launches SCK
falling. That gives **40 ns**, with **14.5 ns gross budget** remaining in the
25.5 ns scenario (9.5 ns at 30.5 ns). These are not post-route slack values.
The nibble counter and byte-valid schedule remain the same. Nonblocking updates
make the completed byte available for the downstream consumer on the same cycle
as before. No registers, counters or protocol cycles are added at RTL level;
actual mapped area is not evaluated here. Integration results are recorded below.

Hold must also be checked: the next nibble begins propagating after that newly
launched falling edge. Min outgoing/returning delay and memory hold protect the
capture, but a full min-delay/clock-skew analysis is still required.

## Reproducible directed comparison

Run from the repository root:

```sh
python3 reports/board_timing/experiment/run.py
```

The historical runner reads the frozen original qspi_ctrl.v snapshot and generates the candidate separately,
and uses Icarus with the existing independent QPI model. Each scenario writes
64 bytes in two-byte transactions, verifies memory, then checks 480 returned
bytes across 1/2/4/8-byte reads at 32 start addresses. It checks write setup/hold,
CS setup/hold/recovery, clock pulse minima and CS-low duration (test limit 3 us).
Explicit numeric MAX_CS_LOW avoids Icarus interpreting the model's time-literal
parameter incorrectly. No production model changes are made.

| Core MHz | Forward + return + memory delay (ns) | Original errors / 480 | Candidate errors / 480 |
|---:|---:|---:|---:|
| 50 | 0 + 0 + 0 (ideal) | 0 | 0 |
| 50 | 4 + 4 + 5.5 | 0 | 0 |
| 50 | 10 + 10 + 5.5 | 480 | 0 |
| 50 | 12.5 + 12.5 + 5.5 | 480 | 0 |
| 25 | 10 + 10 + 5.5 | 0 | 0 |

Every 50 MHz case takes 131.280 us for the complete directed sequence, including
reset/driver overhead, for both versions. Raw logs, source hash, and JSON results
are in `reports/board_timing/experiment/`. Expected original-RTL failures are
asserted by the runner, rather than being mistaken for passing memory tests.

Forward delay is common to SCK/CS/data/OE; the equal forward/return split is an
assumption. No per-pin skew, analog slew, metastability, gate SDF or PVT variation
is modeled. The ideal case is functional only, particularly at zero-delay edges.
This establishes sensitivity and a promising fix, not electrical signoff.

## Other interfaces and remaining constraints

At 50 MHz, nominal outgoing write data setup/hold are 20 ns before path skew,
CS setup is 20 ns, final CS hold is 40 ns, and minimum CS-high recovery is 60 ns.
An eight-byte read holds CS low for 1.14 us. Directed checks pass under common-path
delay assumptions; analog edges and relative pin delay still need verification.
Leave CK open for the baseline; adding clock-only delay affects both write setup
and read return timing and cannot be treated as a universal fix.

UART divider 87 gives 574712.64 baud, about -0.224% relative to 576000 baud.
RX already has two synchronization stages; asynchronous RX is not a synchronous
20 ns input-delay interface. Only the input-to-first-synchronizer timing should
be treated as asynchronous; retain timing between synchronizer stages. Reset has
asynchronous assertion and synchronized release; recovery/removal and fanout
still need appropriate checks. MCU must finish PSRAM provisioning/QPI setup and
release shared pins before accelerator use.

`syn/cons/top.sdc` still applies historical 20 ns input/output delays to all data
ports with a 20 ns core period. This does not represent the source-synchronous
QSPI interface or asynchronous UART. Keep the existing IO failures visible; do
not lower arbitrary IO budgets or false-path all QSPI to manufacture a pass.
The next constraint revision needs generated-SCK edge relationships, both min
and max read return delays, write setup/hold relative to SCK, OE turnaround, and
actual pad/mux paths outside the hard macro. The 0.033442 pF hard-macro load is
not a package load; do not replace it with PSRAM's 15 pF directly.

The earlier +4.45 ns internal setup result covers a different boundary and does
not prove external IO. This review does not claim an updated STA signoff.
`info.yaml` also still advertises 10 MHz and labels PSRAM A CS as unused; update
those metadata alongside the eventual 50 MHz board configuration.

Next physical check: evaluate the modified RTL's routed min/max IO paths with the
shuttle mux and pad model when a physical run is requested. Keep 50 MHz as a
target pending that verification.

## Applied change and regression

The read register now captures in the `sck == 1 && state == DATA` branch, on the
same core edge that launches falling SCK and advances the nibble counter. The
core clock edge is unchanged; SCK is not used as a new RTL clock. `byte_valid`,
`done`, write handling, and request scheduling are unchanged. There is no added
state or storage.

Run the maintained production-RTL regression from the repository root:

```sh
make -f test/Makefile.qspi_timing
```

It is included in CI and fails on any returned-data mismatch or transaction
schedule change. All five scenarios passed (480 bytes each). Every 50 MHz
sequence still takes 131.280 us / 6564 core cycles. Results are saved under
`reports/board_timing/applied/` for this run.

The existing top-level cocotb suite passed 4/4 tests: program execution/replay,
framing bounds and partial input, reset during QPI, and UART framing faults.
The existing suite uses an ideal pin model; the separate directed regression
covers explicit external delays. Neither is gate-level timing signoff.


All 12 existing Bishop network cases also passed through state updates and final
FC output. Outputs matched the reference, and all reported counters (total/core
cycles, fetches, arbitration waits, maximum CS-low duration) matched the previous
results exactly. Reports: `reports/board_timing/applied/network/summary.json`.
These are the existing 12 fixtures, not a new continuous sensor-stream test.
