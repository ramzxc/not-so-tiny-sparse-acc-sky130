# Current PSRAM stream: 20 ms arrivals, 100 ms deadlines

Twelve independent warm-started full-network RTL frame measurements with buffered SRAM. FIFO projection, empty queue per three-frame window, no inter-frame gaps. Not full-trace mean or live streaming validation. 50MHz cycle conversion, not physical timing signoff. Optimistic variant subtracts setup and output phases and UART overhead.

| Dataset | Consecutive steps | Total service times (ms) | Total response times (ms) | Optimistic third response (ms) |
|---|---|---|---|---|
| bishop_0 | 25517–25519 | 49.918, 56.369, 75.269 | 49.918, 86.286, 141.556 | 127.128 |
| bishop_1 | 23479–23481 | 48.031, 59.673, 71.701 | 48.031, 87.705, 139.406 | 124.829 |
| bishop_2 | 24065–24067 | 60.946, 66.430, 75.908 | 60.946, 107.376, 163.284 | 148.707 |
| bishop_3 | 20251–20253 | 63.576, 63.925, 70.446 | 63.576, 107.502, 157.947 | 143.218 |

Each frame checks all 256 c states, all 256 y states, two FC values and PSRAM output. Full EGRU/FC, instruction/weight fetch and result store are included. The queue recurrence is finish[i] = max(20*i, finish[i-1]) + service[i]. Total includes UART ingress and completion credit. Program-only removes those UART costs. The optimistic sensitivity additionally removes initialization and output phases; it is not an implemented streaming mode.

Selected windows establish counterexamples if any response exceeds 100 ms. They do not estimate average workload, full-trace maximum queue size or the minimum clock that would pass all frames.

Reproduce: `make -f test/Makefile.psram_network build BUILD=/tmp/acc-deadline-buffered`, then `python3 scripts/evaluate_stream_deadline.py`. Raw measurements and queue projections: `reports/stream_deadline/summary.json`. No RTL edits or synthesis.
