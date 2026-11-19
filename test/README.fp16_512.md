> Historical FP16 / 512 B tests and timing experiments. See README.md for current defaults.

# RTL tests

Install Verilator >= 5.036 and `requirements.txt`. Run from the repository root:

```sh
make -C test
python3 -m cocotb_tools.check_results test/results.xml
make -C test -f Makefile.exec
python3 -m cocotb_tools.check_results /tmp/acc-fp16-exec/results.xml
make -C test -f Makefile.mem_itf
python3 -m cocotb_tools.check_results /tmp/acc-mem-itf/results.xml
make -C test -f Makefile.qspi
python3 -m cocotb_tools.check_results /tmp/acc-qspi-burst/results.xml
make -C test -f Makefile.micro
python3 -m cocotb_tools.check_results /tmp/acc-micro/results.xml
make -C test -f Makefile.data_ctrl
make -C test -f Makefile.activation
```

- The default test drives real UART instructions and QSPI Flash pins. Only the
  external Flash model is preloaded. It exercises FP16 execution, SRAM storage,
  accumulation, sparse reads, boundary addresses and retained data after reset.
- `Makefile.exec` checks FP16 operations and activations against a Python model,
  scalar selection, sparse zero bypass and snapshots during execution.
- The UART test also exercises two prefetched inputs, explicit column selection,
  repeated accumulation, selected-zero weight skipping and nonzero subnormals.
- `Makefile.mem_itf` checks all 128 SRAM vectors, neighboring halves of a word,
  accumulation, invalid accesses and reset cancellation using the OpenRAM model.
- `Makefile.dma` checks random request/response delays, completion after writes,
  full-range validation, zero length, reset and fault draining. UART tests copy
  all 512 B bit-for-bit in one Flash read transaction, preserve adjacent SRAM halves and execution operands,
  and run computation from DMA-loaded inputs and weights.
- `Makefile.qspi` checks burst bytes and CS continuity under random consumer
  stalls, unaligned/page-crossing reads, busy polling, paused-stream abort, reset,
  and fresh transactions after a burst. It compares single-byte/burst cycles.
- `Makefile.micro` checks the emitted instruction stream under random stalls,
  automatic cur, zero columns, pointer carry, maximum loop counts, faults and reset.
  The UART tests check full SRAM partial-sum updates from Flash/SRAM operands,
  repeated runs, dense NaNs, zero lengths and output-range errors. Batch tests
  cover randomized stalls, sizes 2/3/128, SRAM bounds and weight-read reuse.
  Automatic DMA tests cover exact emitted command streams, packed/strided
  columns, batch sizes 1/2/3/7/63/127, all-zero column scans, complete SRAM
  overlap/range checks and DMA faults. UART tests exercise batch=1/3/4,
  independent output tiles, split input dimensions, bias/partial-sum retention,
  dense NaNs, Flash/SRAM inputs, mode switching and reset during auto DMA.
  The UART batch test checks separate partial sums and repeated tile accumulation.
- `Makefile.data_ctrl` checks address post-increment during stalls, sparse skips,
  carry, overflow and reset. The UART test also checks consecutive Flash/SRAM
  reads, writes, accumulation and the SRAM end boundary.
- `Makefile.activation` checks all 65,536 FP16 encodings for each of five
  activation modes through EXEC multiply-by-one against an independent Python
  oracle, including NaNs, signed zero, atomic output updates, held outputs and reset.

Build outputs default to `/tmp`; the default test writes `test/results.xml`.
`BUILD=/tmp/another-build` selects a different build directory.

`GATES=yes` selects the packaged gate netlist and cell models. The checked-in
macro still implements the previous core, so it needs rebuilding before the
new protocol can pass gate-level tests. RTL tests are not post-layout validation.

## Throughput measurement

`make -C test -f Makefile.perf` uses hardware UART divider 87 and records DMA,
MICRO and host-driven tile cycles in `/tmp/acc-throughput-hw/measurements.json`.
Testbench counters do not modify the core. `scripts/evaluate_bishop_throughput.py`
combines these with local Bishop workload statistics. See
[`docs/performance.md`](../docs/performance.md) for assumptions and limitations;
this is not a full-network or physical-timing pass.

Automatic DMA performance can be measured with:

```sh
make -C test -f Makefile.perf BUILD=/tmp/acc-auto-dma-perf COCOTB_TEST_MODULES=test_auto_dma_performance
```

This uses hardware UART divider 87 and reports both MICRO busy cycles (including
its DMA waits) and host configuration/RUN/SYNC cycles for batch 1 and 4.

## Bishop input-pattern timing replay

Prepare external Flash fixtures, run the current auto-DMA RTL at the hardware
UART divider, and evaluate input-projection tile schedules:

```sh
python3 scripts/prepare_bishop_perf.py
make -C test -f Makefile.perf BUILD=/tmp/acc-bishop-eval COCOTB_TEST_MODULES=test_bishop_performance SIM_ARGS=+perf_flash_file=/tmp/acc-bishop-eval/inputs.hex
python3 scripts/evaluate_bishop_auto_dma.py
```

Run these commands from the repository root with cocotb on PATH. The 48 tile
cases verify cycle timing and Flash transaction counts. Nonzero inputs are
replaced with FP16 one: this is a sparsity/timing experiment, not an EGRU accuracy
test. See `docs/performance.md` for omissions and deadline interpretation.

## Host stream equivalence and performance

The host-only optimization retains clock, baud, RTL, sparsity behavior and
arithmetic order. It streams queued MICRO runs, fences at an observable boundary,
and omits address high words only when their value is known. It does not remove
the core SYNC instructions needed for ordinary dependent MEM/EXEC operations.

```sh
python3 scripts/prepare_stream_perf.py
make -C test -f Makefile.perf BUILD=/tmp/acc-stream-compact COCOTB_TEST_MODULES=test_stream_performance SIM_ARGS=+perf_flash_file=/tmp/acc-stream-eval/inputs.hex
PERF_CASES=/tmp/acc-stream-eval/mixed.json make -C test -f Makefile.perf BUILD=/tmp/acc-stream-mixed COCOTB_TEST_MODULES=test_stream_performance SIM_ARGS=+perf_flash_file=/tmp/acc-stream-eval/inputs.hex
make -C test -f Makefile.perf BUILD=/tmp/acc-stream-protocol PERF_UART_CLKS_PER_BIT=8 COCOTB_TEST_MODULES=test_stream_protocol
python3 scripts/compare_bishop_stream.py
```

The comparison script also needs the preceding Bishop timing evaluation's
`reports/bishop_auto_dma/estimate.json`. Performance runs use UART divider 87;
the separate protocol regression uses divider 8. All inputs/output initialization
are delivered through Flash DMA. A read-only SRAM snapshot verifies results
immediately after the UART fence, without adding readback waits that could mask
an early-return bug. No DUT/SRAM backdoor writes are used.

Nineteen uniform and three mixed-length chains compare baseline, streamed and
compact schedules bit for bit, as well as against exactly representable finite
FP16 sums. They also compare MICRO/DMA cycles and Flash transactions. The separate
protocol test checks low Flash addresses and conservative Flash-input handling.
