# RTL interface grouping

The top-level now connects three larger control blocks. This is a structural
refactor; it does not add buffering, arithmetic, arbitration stages or cycles.

| Public block | Owns | Connects to |
|---|---|---|
| `input_queue` | UART receive storage, frame assembly, PSRAM ring addresses, complete-frame replay, overflow reporting | UART RX, command input, QSPI queue request port |
| `command_ctrl` | Program configuration, SRAM input loading, 64-bit instruction buffer, generic MICRO sequencing | Input queue, SRAM input port, DMA command port, QSPI fetch port |
| `qspi_ctrl` | Data/fetch arbitration, queue/core arbitration, QPI transfers and completion routing | Input queue, memory backend, command fetch, PSRAM pins |

The DMA remains a PSRAM-to-SRAM copy requester in the compute path. It does not
own the serial bus: input queue and instruction fetch are independent requesters.

`input_queue` directly contains the receive storage previously instantiated as
`inst_fifo`. Default depth is one 16-bit word; the configurable deeper form remains
for directed backpressure/overflow tests. The head retires only on write
completion. Full simultaneous pop/push is preserved. Ring-full behavior and raw
UART protocol are unchanged.

`core/command_ctrl.v` contains the public controller and its implementation modules,
`program_fetch` and `micro_ctrl`. Fetch and sequencing retain their distinct FSMs
and existing ready/valid handshake. This avoids introducing a new combined FSM
or changing the order of input loading, instruction issuance and execution.
The outer core sees only the expanded command stream. MICRO remains generic,
including sparse columns, batching and automatic DMA tiles.

`qspi_ctrl.v` contains the public three-requester interface and its implementation
modules, `psram_arbiter` and `qpi_engine`. Both existing arbiter instances are
retained internally so arbitration and turnaround timing remain unchanged.
Priority stays queue > data/DMA > instruction fetch at transaction boundaries;
active transfers are never interrupted. Read data is shared, while byte-valid
and completion are routed only to the owner. `bus_busy` reports the existing
core-side ownership state used by program completion logic; it is not a new
all-traffic-idle indication.

Old standalone `program_ctrl.v`, `core/micro_ctrl.v`, `core/inst_fifo.v`,
`psram_arbiter.v`, and `uart_psram_queue.v` are folded into these files.
Source lists, unit-test compilation paths, integration observation paths and
profiling hierarchy references follow the new grouping. The SRAM hierarchy
remains unchanged. The public top-level pinout and UART/PSRAM protocols are
unchanged.

Verification compares the two full-network eight-frame runs against
`reports/uart_ingress_fifo/network/summary.json`, including exact completion
cycles, numeric/input mismatches, maximum input-write delay and contention
counters. Results are under `reports/interface_refactor/`. Also run legacy UART,
raw queue, MICRO batching/stalls, both arbiter configurations, receive FIFO
stall/order/full/reset, and QPI delayed-return tests. The network profiling
bench is compiled against the updated hierarchy.

No synthesis or PnR is performed for the refactor. The earlier physical result
is retained with its source snapshot; module grouping alone is not evidence of
an area reduction or physical timing equivalence.
