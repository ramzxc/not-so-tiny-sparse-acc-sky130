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
but its FP16 test functions are not the default suite. Old gate-level netlists
and the old GL harness are not validated against this new build.
