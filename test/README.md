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
