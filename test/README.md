Current optimized revision: row-bounded DMA and compact SRAM operations. See
[stage results](../docs/optimization_stages.md). Run the default integration suite,
MICRO, DMA, mem_itf, arbiter, data_ctrl, and `python3 -m unittest discover -s test
-p test_compact_sram.py`. Full network fixtures apply safe stored-command folding.
The old `summarize_bottleneck.py` intentionally checks its saved baseline; use
`summarize_optimization_stages.py` for current staged results instead.

Passive full-network profiling (current restored MICRO):
`make -f test/Makefile.psram_network build fixtures BUILD=/tmp/acc-bottleneck`,
then `python3 scripts/run_psram_network.py --binary /tmp/acc-bottleneck/Vtb_psram_network --profile`
and `python3 scripts/summarize_bottleneck.py`, all from repository root.
See [measured bottlenecks](../docs/bottleneck.md). Functional RTL is unchanged.

# Current default: UART input / PSRAM programs and weights

`make -C test` runs the PSRAM stream suite. See [the interface contract](../docs/psram_stream.md)
and `Makefile.stream`, `Makefile.arbiter`, `Makefile.psram_network`.
The following Flash/UART-instruction benchmark commands are historical and
require their earlier RTL snapshot; they are not the current top-level protocol.
The standalone FP8 EXEC, MICRO, DMA, data-control and SRAM suites remain current.
The software-lowered MICRO experiment has been rolled back. Its tests and compiler
are archived under `reports/micro_reduction/reverted_stage/`; they are not current.

# FP8 E4M3FN / 1 KiB tests

Run from this directory with cocotb 2.x, Verilator and Icarus available:

```sh
make BUILD=/tmp/acc-fp8-serial COCOTB_RESULTS_FILE=/tmp/acc-fp8-serial/results.xml
python -m cocotb_tools.check_results /tmp/acc-fp8-serial/results.xml
make -f Makefile.exec
make -f Makefile.micro
make -f Makefile.dma
make -f Makefile.mem_itf
make -f Makefile.data_ctrl
bash run_fp8_math.sh
```

Use `cocotb_tools.check_results` on each cocotb suite's output XML. The default
serial suite uses `tb_fp8_serial.sv`, UART divider 8, real QSPI pins and the
existing 64x128 OpenRAM timing model. All stimuli are in external Flash; SRAM
snapshots are read-only observations. No DUT/SRAM backdoor initialization is used.

Coverage includes all 1,024 SRAM bytes and four independently preserved vector
slots per row, FP8 read-add-write, 255-vector burst copies, address 1022, odd and
out-of-range rejection, post-increment, strided output tiles, batch 1/3/4,
Flash/SRAM inputs, sparse/dense NaNs, reset and transition to ordinary MICRO.
The sequencer unit test checks batch 1..128 representative cases, 255 groups,
DMA reuse and randomized backpressure. Arithmetic tests use the independent
exact-rational oracle: all 65,536 ADD and MUL pairs, pack rounding, every FP8
activation input, vector/scalar snapshots and accumulation.

`Makefile.activation` selects the exhaustive activation test alone.
`Makefile.perf` runs **FP8 component-only** timing measurements at UART divider 87
and writes `measurements.json` under BUILD. It is not a full-network benchmark.

The old FP16 fixtures and experiments remain for provenance; they are not valid
FP8 input images. See [README.fp16_512.md](README.fp16_512.md) for their historical
instructions. `test_serial.py` still supplies the format-independent UART Host,
but its FP16 test functions are not the default suite.

`GATES=yes make` selects `Makefile.gates` and the freshly downloaded
`gate_level_netlist.v` (override with `GATE_NETLIST`). It uses the active
`PDK_ROOT`/`PDK` standard-cell models and the supplied 1 KiB SRAM behavioral
model. Pin-level checks run at 50 MHz / UART divider 87: multiply, MICRO batch
1 and 3 with replay, output-enable gating, and two raw UART frames written to
and consumed from PSRAM. Results are checked at the external PSRAM. There are
no RTL-state probes or SRAM preloads. This is zero-delay functional GLS without
SDF; it does not certify post-layout timing. Historical netlists remain invalid.

## Converted Bishop test data

From the repository root:

```sh
python3 scripts/prepare_bishop_fp8.py
make -C test BUILD=/tmp/acc-bishop-fp8-data COCOTB_TEST_MODULES=test_bishop_fp8 COCOTB_RESULTS_FILE=/tmp/acc-bishop-fp8-data/results.xml SIM_ARGS=+FIXTURE="$PWD/reports/fp8_1k/data/rtl_flash.hex"
python -m cocotb_tools.check_results /tmp/acc-bishop-fp8-data/results.xml
```

The converter reads the four `egru/sim/data/sdc_raw/bishop_*/fp16` datasets and
writes test-only files under `reports/fp8_1k/data/bishop_*`, without editing the
sources. `weights.npz`, `test.npz` and raw `.bin` arrays store E4M3FN encodings as
uint8. Decode the FP8 bit patterns; an ordinary uint8-to-float cast is incorrect.
Raw binaries use C order. No gate reorder, bias folding or scale change is made.
Only `test.inputs` is converted; labels, targets and trial metadata remain intact.
The source `input_saturation_count` describes the original export, not FP8;
FP8 clipping/underflow/error statistics and source/output hashes are in the manifest.

All 65,536 binary16 patterns are checked against the exact-rational converter.
The RTL fixture then runs actual full input dimensions (184–187 columns) onto
eight output channels for batch 1 and 4 across Bishop 0–3, spanning the three
input gate blocks. Output bits and Flash burst counts are checked independently.
This checks data conversion, packing and the matrix primitive; it is not complete
EGRU/FC inference, task accuracy evaluation, or a real-time performance guarantee.

## Complete EGRU + FC performance

From the repository root, after converting the Bishop data:

```sh
make -f test/Makefile.network
python3 scripts/summarize_fp8_network.py
```

This native Verilator bench sends the entire batch-1 workload through UART,
including elementwise state updates and the final two-output FC layer. It compares
all cell/output states and FC outputs to the independent FP8 reference on selected
warm-started Bishop frames. See [the full-network report](../docs/performance_fp8_1k.md)
for measured scope, external I/O exclusions and reproduction details. The complete
software traces are not a full-dataset RTL timing run or a task-accuracy evaluation.

To isolate front-end command supply, core processing, and Flash result emission:

```sh
make -f test/Makefile.consumer
```

Run this from the repository root after generating the FP8 software traces.
The [consumer report](../docs/performance_fp8_consumer.md) separates ideal command
availability from actual UART feeding, verifies the emitted Flash bytes, and
labels full-trace timing/queue projections separately from selected RTL runs.

## QSPI board-delay regression

From the repository root, run `make -f test/Makefile.qspi_timing` (Icarus).
This tests current production RTL with five explicit delay scenarios, checks
480 returned bytes per scenario and unchanged transaction duration, and checks
write/CS timing. It covers the full-period PSRAM read sampling fix. Delay values
are sensitivity assumptions, not guaranteed board/PVT timing. See
[board timing review](../docs/board_timing.md).

## Experimental no-PC-buffer ingress

`core/command_ctrl.v` groups program fetch and MICRO sequencing inside the compute core directory. `input_queue.v` owns UART receive buffering and the PSRAM frame queue. `qspi_ctrl.v` owns both request arbitration and the QPI wire engine.
Run the new four-slot queue stress tests from `test/`:

```sh
make BUILD=/tmp/acc-no-pc-queue COCOTB_RESULTS_FILE=/tmp/acc-no-pc-queue/results.xml COCOTB_TEST_MODULES=test_psram_queue QUEUE_SLOT_BITS=2
python -m cocotb_tools.check_results /tmp/acc-no-pc-queue/results.xml
```

The existing default tests still cover legacy operation. Test both arbitration
modes with `make -f Makefile.arbiter FETCH_WRITES=0` and `FETCH_WRITES=1` using
different BUILD paths. Full-network fixed-rate tests run from the repository root
with `make -f test/Makefile.no_pc build run`, using existing Bishop fixtures.
See [experiment scope and results](../docs/no_pc_buffer.md).
