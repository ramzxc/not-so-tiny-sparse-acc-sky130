# Not-so-tiny sparse accelerator — SKY130

Experimental Tiny Tapeout SKY130 8×2 submission with one 512 B OpenRAM SRAM.
GitHub Actions validates RTL, hardening, precheck and gate-level simulation.

- Two-lane FP16 TPU with SPI host interface.
- Software-managed weight buffer; cache and replacement logic are disconnected.
- One shared OpenRAM 1RW SRAM: selectable 1 KiB or 512 B; UB/ACC/WB partitioned 1/2, 1/4, 1/4.
- Two FP16 lanes; two 32-bit rows per physical 64-bit SRAM word. Partial writes use atomic read-modify-write.
- [Protocol and implementation limits](docs/info.md).
- Compile SRAM libraries: `lc_shell -f syn/compile_openram.tcl`.
- Synthesis: `ACC_SRAM_BYTES=512 dc_shell -f syn/run_dc.tcl` in the local synthesis workspace; local `syn/` and `pnr/` outputs are excluded from submission.
- RTL tests: `make -C test SRAM_BYTES=512`; controller stress test: `make -C test -f Makefile.mem SRAM_BYTES=512`.
- P&R configs: `src/config_1024.json` or `src/config_512.json`; `src/config.json` defaults to 512 B.

# Tiny Tapeout Verilog Project Template

- [Read the documentation for project](docs/info.md)

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that aims to make it easier and cheaper than ever to get your digital and analog designs manufactured on a real chip.

To learn more and get started, visit https://tinytapeout.com.

## Set up your Verilog project

1. Add your Verilog files to the `src` folder.
2. Edit the [info.yaml](info.yaml) and update information about your project, paying special attention to the `source_files` and `top_module` properties. If you are upgrading an existing Tiny Tapeout project, check out our [online info.yaml migration tool](https://tinytapeout.github.io/tt-yaml-upgrade-tool/).
3. Edit [docs/info.md](docs/info.md) and add a description of your project.
4. Adapt the testbench to your design. See [test/README.md](test/README.md) for more information.

The GitHub action will automatically build the ASIC files using [LibreLane](https://www.zerotoasiccourse.com/terminology/librelane/).

## Enable GitHub actions to build the results page

- [Enabling GitHub Pages](https://tinytapeout.com/faq/#my-github-action-is-failing-on-the-pages-part)

## Resources

- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Learn how semiconductors work](https://tinytapeout.com/siliwiz/)
- [Join the community](https://tinytapeout.com/discord)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)

## What next?

- [Submit your design to the next shuttle](https://app.tinytapeout.com/).
- Edit [this README](README.md) and explain your design, how it works, and how to test it.
- Share your project on your social network of choice:
  - LinkedIn [#tinytapeout](https://www.linkedin.com/search/results/content/?keywords=%23tinytapeout) [@TinyTapeout](https://www.linkedin.com/company/100708654/)
  - Mastodon [#tinytapeout](https://chaos.social/tags/tinytapeout) [@matthewvenn](https://chaos.social/@matthewvenn)
  - X (formerly Twitter) [#tinytapeout](https://twitter.com/hashtag/tinytapeout) [@tinytapeout](https://twitter.com/tinytapeout)
  - Bluesky [@tinytapeout.com](https://bsky.app/profile/tinytapeout.com)
