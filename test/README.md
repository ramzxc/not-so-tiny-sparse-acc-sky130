# RTL tests

Install Verilator >= 5.036 and `requirements.txt`. Run from the repository root:

```sh
make -C test
python3 -m cocotb_tools.check_results test/results.xml
```

- The default test uses the Tiny Tapeout wrapper with the current FP8 RTL
  from `src/sources.f`. It checks QPI boot, UART input, DMA, FP8 execution,
  and UART output. The bench is in `rtl/tb/` and the QPI models are in
  `rtl/models/`.

Build outputs default to `/tmp`; the default test writes `test/results.xml`.
`BUILD=/tmp/another-build` selects a different build directory.

`GATES=yes` selects the routed netlists and PDK cell models. It runs the
wrapper smoke test with the packaged macro's UART configuration. This uses
the `gate_level_netlist.v` produced by the Tiny Tapeout flow.
