# Aligned weight scratch: measured comparison

Software-only SRAM layout change. No functional RTL, SRAM capacity, numerical precision or operation order change; no synthesis.

| Region | Before | After |
|---|---|---|
| Input | 768–955 | unchanged |
| Weight / threshold scratch | 956–979 | 960–983 |
| U/R/Z | 980–1003 | 984–1007 |
| Temporary A | 1004–1011 | 1008–1009 |
| Temporary B | 1012–1019 | 1010–1011 |
| FC / constant ones | 1020–1023 | unchanged |

Each state-update pair consumes both temporary vectors before the next pair starts. Reusing those four bytes frees space to align the 24-byte scratch and accumulator region. All named regions are checked for overlap and containment. Architectural c, old y and new y remain unchanged.

## Same slow frame at 50 MHz

| Metric | Before | After |
|---|---:|---:|
| Internal program | 77.704 ms | 71.145 ms |
| UART through completion | 82.468 ms | 75.908 ms |
| DMA total | 31.120 ms | 24.561 ms |
| External data requests | 27,802 | 18,938 |

Bishop 2 step 24067 saves 6.55932 ms (8.44% of program time). The improvement exceeds the earlier 4.752 ms protocol-only estimate: fewer chunks also remove SRAM preservation/commit and DMA handoff cycles. Aligned bias and threshold copies contribute as well. All non-DMA exclusive category cycle counts remain identical across the twelve paired cases.

## 100 ms per-input deadline

Inputs arrive at 0/20/40 ms. The deadline is each arrival plus 100 ms, including queue wait. Each window starts empty.

| Dataset | Before maximum latency | After maximum latency | Pass |
|---|---:|---:|---|
| bishop_0 | 156.450 ms | 141.556 ms | no |
| bishop_1 | 153.850 ms | 139.406 ms | no |
| bishop_2 | 179.434 ms | 163.284 ms | no |
| bishop_3 | 173.505 ms | 157.947 ms | no |

The hardest window now requires 203.28422 ms of service; the third result must finish by 140 ms. Another 63.28422 ms (31.13% of this window service) must be removed to meet that necessary bound. This is not a target requiring every individual frame to finish within 20 ms. Earlier deadlines and longer sequences must also pass.

## Validation and next step

12 adjacent-frame runs plus 12 standard runs pass (20 distinct frames). Every run checks all 256 c states, 256 y states, both FC values and PSRAM output. Reference outputs are byte-identical to baseline. Arithmetic counts, sparse decisions, payload bytes and stored instruction counts are unchanged. Source hashes confirm no functional RTL changes.

The retained software change improves performance without new hardware. Remaining dominant costs in the representative frame: DMA 24.561 ms; MICRO control/handoff 20.818 ms. Next review DATA/MICRO request/completion handoff, especially W_SYNC and A_SYNC, while preserving generic batch/network behavior. No such RTL optimization is included here.

RTL simulations at an assumed 50MHz; FIFO calculation from independent warm-state frames. Empty queue per selected window. Not full-trace throughput, live-stream test, synthesis or physical timing signoff.

Reproduce with `python3 scripts/evaluate_stream_deadline.py`, `python3 scripts/prepare_psram_network.py`, `python3 scripts/run_psram_network.py --binary /tmp/acc-deadline-buffered/Vtb_psram_network --profile`, then `python3 scripts/compare_weight_alignment.py`. Baseline is preserved in `reports/weight_alignment/before`; raw comparison is `reports/weight_alignment/comparison.json`.
