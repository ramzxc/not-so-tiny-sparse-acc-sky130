# No-PC-buffer optimization and finite-recording queue capacity

Branch: `experiment/no-pc-buffer`. Comparison baseline: `5c158d4`. No synthesis or PNR.

Acceptance for this experiment is **no PC backlog and no input-queue overflow during the recording**, followed by complete draining. There is no per-input 100 ms deadline.

## Applied RTL changes

- MICRO uses the existing compact SRAM input instruction on validated auto-DMA/SRAM paths, replacing DATA + address low/high + MEM with one command. Scalar/vector and sparse modes remain generic for all batch sizes. External-input and non-DMA paths retain the original sequence.
- DATA permits a pure SYNC to retire on the same clock edge as operand capture or completed-write retirement. Other instructions still require IDLE. A dependent operation therefore follows the capture edge, rather than consuming stale data.
- No payload storage, arithmetic units, registers or numerical precision are added/changed by these two optimizations. Combinational decode changes; mapped area and physical timing are unmeasured.

## Full-network program time at assumed 50 MHz

Timing model fitted on 20 RTL frames and independently checked on 16 holdouts, for both versions. All 72 runs matched c/y state, FC and PSRAM output. The fitted model has zero cycle error on all 36 frames of each version. Whole-trace means below project that model onto 103,133 actual activity steps; they are not whole-trace RTL runs.

| Dataset | Before mean ms | After mean ms | Reduction |
|---|---:|---:|---:|
| Bishop 0 | 24.667 | 23.067 | 6.49% |
| Bishop 1 | 25.926 | 24.262 | 6.42% |
| Bishop 2 | 23.873 | 22.307 | 6.56% |
| Bishop 3 | 23.283 | 21.741 | 6.62% |

Model coefficients `[dataset bases × 4, active input, previous y, new y]`:

- Before: `[422302, 423094, 423094, 423632, 16352, 16096, 76]`
- After: `[380660, 381226, 381226, 381550, 15584, 15328, 74]`

## When accumulation becomes a problem

The default ring has **16,384 fixed 256-byte slots (4 MiB)**. A full ring followed by another incoming word sets a sticky error; the receiver does not silently overwrite queued frames. An elapsed response time alone is not an overflow threshold. The current frame is moved to the 1 KiB SRAM and frees its PSRAM slot before computation finishes.

For each recorded file, starting with an empty queue and delivering frames continuously every 20 ms, projected usage stays below capacity. The conservative sizing scenario retains all legacy UART time (does not claim overlap savings), adds 0.3 ms/frame queue overhead, and then slows the entire service by 10%. Those transport/slowdown numbers are sensitivity assumptions, not a formally proven hardware bound. Counts also retain the in-service frame conservatively.

| Dataset | Recording min | Before peak MiB | After peak MiB | After peak slots / 16,384 | Drain after input stops, min |
|---|---:|---:|---:|---:|---:|
| Bishop 0 | 10.44 | 2.859 | 2.589 | 10,605 | 5.68 |
| Bishop 1 | 8.32 | 2.478 | 2.265 | 9,276 | 5.10 |
| Bishop 2 | 8.51 | 2.263 | 2.046 | 8,382 | 4.30 |
| Bishop 3 | 7.10 | 1.852 | 1.654 | 6,774 | 3.39 |

**These files fit because the finite backlog fits memory, not because quiet portions fully clear it.** Even the optimistic core-only model recovers only near the beginning (last recovery at approximately 1.6–2.3 s), then retains backlog through capture end. Quiet periods can reduce it without eliminating it. After capture stops, processing can drain it; wait for drain before resetting/reconfiguring or treating the next file as an empty-queue session.

This is per-file capacity, not all files concatenated or indefinite acquisition. Repeating each activity trace for one hour overflows the 4 MiB ring in the conservative +10% scenario:

| Repeated trace | First modeled overflow, min |
|---|---:|
| Bishop 0 | 15.47 |
| Bishop 1 | 14.40 |
| Bishop 2 | 16.46 |
| Bishop 3 | 16.92 |

The faster illustrative overlap model and the ideal core-only model are retained separately in JSON. They are not used to claim worst-case timing. Actual UART/PSRAM stalls, other activity patterns, missing/extra bytes, and real trial gaps can change queue usage. Reference traces are warm-state software trajectories, so live recurrent state carry still needs a distinct end-to-end test.

## Fixed-rate concurrent RTL experiment

At actual modeled 50 MHz/divider 87, send eight full input frames at 20 ms intervals without waiting for READY. Repeated warm-start fixtures check transport plus full EGRU/FC, not a new continuous recurrent trajectory.

| Fixture | Before last response ms | After last response ms | Before/after peak queued slots |
|---|---:|---:|---:|
| Bishop 2 step 100 | 16.986 | 15.903 | 1 / 1 |
| Bishop 2 step 24067 | 433.079 | 402.660 | 6 / 5 |

All inputs and outputs match. Response time is a diagnostic only; there is no 100 ms pass/fail criterion here.

## Program address reservation correction

The old test images placed instructions at `0x600000`, inside the newly reserved queue. Eight frames did not reach those addresses, so the earlier short-test results remain valid but could not establish safe use of the entire ring. The streaming runner now relocates instructions to `0x300000`, and both fixture generators use that address for new images. Weights/output remain below `0x400000`. Arbitrary programs still must obey the reservation; the RTL does not police every core address.

## Verification and reproduction

- MICRO sequencer: 4/4, including generic batched/auto-DMA and randomized instruction stalls.
- DATA directed retirement/postincrement checks: pass, including no early write SYNC and no ordinary instruction accepted during operand capture.
- Legacy stream integration: 4/4; input queue stress: 3/3.
- Paired full-network fixtures: 36 before + 36 after, zero numerical mismatch and zero timing-model error.
- Concurrent UART/network: 2 cases × 8 frames, zero mismatch.
- Verilator lint: no combinational-loop, latch or multiple-driver findings. Physical timing and area are not evaluated.

Build separate baseline/modified `test/Makefile.psram_network` binaries, then run `python3 scripts/evaluate_no_pc_optimization.py --before BASELINE_BINARY --after MODIFIED_BINARY`. The script reads existing fixtures without overwriting their reference results. `--reuse` recalculates projections from saved measurements.

Run `scripts/run_no_pc_network.py --binary STREAM_BINARY --out reports/no_pc_optimization/stream_after` for the updated concurrent-input comparison. Reports, source hashes, binary hashes and logs are under `reports/no_pc_optimization/`.


The validated state above is checkpointed at `0350439` on
`checkpoint/no-pc-buffer-optimized`. The separate
[sustainable-stream experiment](sustainable_stream.md) evaluates further changes;
it does not move this checkpoint.
