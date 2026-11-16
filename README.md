# Not-So-Tiny Sparse Accelerator

An FP16 sparse accelerator for **Tiny Tapeout SKY130**, using **8×2 tiles**.
It combines a two-lane compute engine, an SPI host interface, and a shared 512 B SRAM.

[![GDS](https://github.com/ramzxc/not-so-tiny-sparse-acc-sky130/actions/workflows/gds.yaml/badge.svg)](https://github.com/ramzxc/not-so-tiny-sparse-acc-sky130/actions/workflows/gds.yaml)
[![Tests](https://github.com/ramzxc/not-so-tiny-sparse-acc-sky130/actions/workflows/test.yaml/badge.svg)](https://github.com/ramzxc/not-so-tiny-sparse-acc-sky130/actions/workflows/test.yaml)

## Features

- Two FP16 lanes sharing one physical MAC.
- Sparsity control and ReLU, sigmoid, and tanh activation.
- Software-managed weights and memory accumulation.
- One 512 B OpenRAM SRAM, shared by UB (256 B), ACC (128 B), and WB (128 B).
- SPI host interface and DMA request handling.
- Two-entry instruction FIFO and a 10 MHz target clock.

## Architecture

```text
Tiny Tapeout pins → Wrapper → Accelerator core
                             ├─ SPI host and DMA
                             ├─ Compute, sparsity, and activation
                             └─ Memory controller → 512 B SRAM
```

The core is synthesized with Design Compiler and placed and routed with ICC2.
The Tiny Tapeout flow imports the finished core and builds the wrapper around it.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/wrapper/` | Tiny Tapeout top module |
| `src/rtl/` | Accelerator RTL |
| `src/tcl/` | PDN and Magic scripts used by Actions |
| `src/config.json` | Current 512 B integration settings |
| `macro/acc_hard_macro/` | Core GDS, LEF, netlists, and SPEF |
| `memory/openram/` | SRAM generator and macro files |
| `test/` | RTL and gate-level tests |
| `scripts/` | Integration and reporting tools |
| `docs/` | Interface documentation and archived notes |

### Netlists

- **Post-route:** [acc_hard_macro.v](macro/acc_hard_macro/acc_hard_macro.v)
- **Post-route with power pins:** [acc_hard_macro.pg.v](macro/acc_hard_macro/acc_hard_macro.pg.v)
- **Post-synthesis, local build:** `syn/runs/<run>/acc_hard_macro_gate.v`

## Testing

Requires Python, Make, and Verilator 5.036 or newer. CI uses Verilator 5.052.
Run from the repository root:

```sh
python3 -m pip install -r test/requirements.txt
make -C test SRAM_BYTES=512
python3 -m cocotb_tools.check_results test/results.xml
```

GitHub Actions runs RTL tests, wrapper hardening, DRC/LVS, Tiny Tapeout precheck,
and gate-level simulation. Build results include a 2D preview and a 3D viewer link.

## Documentation

- [Pin assignments](info.yaml)
- [SPI interface](docs/info.md#pins-and-spi-timing)
- [Archived development notes](docs/archive/README.md)
- [Tiny Tapeout](https://tinytapeout.com)
