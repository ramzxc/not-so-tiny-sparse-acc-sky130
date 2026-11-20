# UART ingress buffering

Raw mode (`F400` after `F100` configuration) routes UART payload words through
`input_queue`, which owns both the receive storage and the reserved PSRAM ring. Configuration remains on the legacy
frontend path; payload words are not interpreted as core instructions. The
existing ingress controller performs autonomous writes, without extending the
core DMA or adding another DMA engine.

The default FIFO depth is **one 16-bit word**, with storage and occupancy owned
directly by `input_queue`; there is no separate `inst_fifo` module.
Four entries were initially considered but have no demonstrated throughput
benefit with the current UART and bounded QSPI transactions. Depth remains a
parameter for isolated stress testing. The head stays stable until write
completion; simultaneous completion and reception can replace a full head.

At 50 MHz and UART divider 87, two 8N1 bytes arrive every 1,740 core cycles
(34.8 us). An eight-byte QPI read uses 28 SCK cycles (56 core cycles), plus
selection/completion cycles. A two-byte write uses 12 SCK cycles (24 core
cycles), plus control cycles. Arbitration adds latency; these serial transfer
counts are not a whole-path latency bound. Existing integration tests also
exercise a much faster divider of 8 (160 core cycles per word).

Nonempty receive buffering takes priority over replay at the ingress controller;
the existing outer arbiter prioritizes ingress requests over core requests.
Transactions already in progress finish first. Writes remain two bytes each;
this change does not reduce QSPI transaction count or implement burst writes.

If the PSRAM ring is full, a pending word waits while replay frees space.
If UART supplies another word while the receive FIFO cannot accept it, the
sticky error asserts. Neither finite RAM nor a deeper FIFO can guarantee
lossless operation under indefinite overload. Reset clears queue ownership and
FIFO state. RAM address reservations and UART protocol are unchanged.

Validation:

- `make -f test/Makefile.uart_queue_fifo`: isolated four-entry parameter stress
  test for blocked QSPI, ordering, stable write data, full simultaneous pop/push,
  full-ring recovery, explicit overflow, and reset.
- `test_psram_queue` with default one-entry FIFO and four-slot PSRAM ring:
  actual UART/QSPI overlap, wraparound, numerical output, partial frames,
  padding, overload/reset, and observed receive-drain latency.
- `test_psram_stream`: legacy protocol regression.

No synthesis or PNR is performed for this change. Physical area and timing are
not claimed from RTL simulation.

Full-network contention measurement (default depth 1, 50 MHz, divider 87):
`reports/uart_ingress_fifo/network/summary.json` records two eight-frame runs
at fixed 20 ms intervals. The light Bishop step 100 run had no ingress/core
bus contention and a maximum pending time of 30 cycles. The heavy step 24067
run had 9,752 total ingress request cycles blocked by core transactions; its
maximum pending receive word time was 90 cycles (1.8 us), compared with at
least 1,740 cycles (34.8 us) between UART words. Both runs had zero numerical
or stored-input mismatches and no DUT error. The heavy run reached five PSRAM
frames queued; this is compute backlog, distinct from the one-word receive
buffer. These are finite repeated warm-start fixtures, not a universal timing
proof or sustained heavy-workload guarantee. No hardware RTL changed for this
measurement; only testbench counters/reporting were added.
