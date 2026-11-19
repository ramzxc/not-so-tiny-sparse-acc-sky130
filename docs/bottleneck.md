# Restored MICRO: full EGRU+FC bottleneck profile

Passive simulation counters only. Functional RTL is byte-identical to the pre-reduction snapshot; no synthesis was run. All 12 full-network numerical results, cycle counts and original bus counters exactly match the saved baseline.

## Measurement boundaries and accounting

- UART front: INPUT/RUN command through the completed input commit, before frontend START.
- Program: START through drain, including state initialization, instruction fetch, full EGRU, FC and PSRAM output. Completion: final READY credit reception. The program-phase output store is part of program time, not a second UART numeric output.
- Initial host CONFIG and MCU provisioning are excluded. These are twelve selected warm-started frames, not a continuous full-trace throughput average. Time assumes a 50 MHz core and 25 MHz QPI SCK; no timing closure claim.
- Every program cycle is assigned exactly once, with priority DMA-read/write → memory access → EXEC → MICRO control → exposed fetch → dispatch/drain. A bucket describes the current blocking/active state; it is not a measured causal speedup. Independent occupancy and state counters may overlap and must not be summed with the partition.
- MICRO control/handoff includes emitted address/mode/SYNC instructions, validation, sparse decisions, pointer updates and operand/result handoff gaps after other active operations have been assigned. It is not all useless waiting.
- Phase attribution uses the generator’s tagged command stream; a new phase starts when its first instruction is accepted. Fetch preceding that instruction can be charged to the preceding phase. Aggregate totals are exact.

## Fastest and slowest selected frames

Fast: bishop_2 step 100; slow: bishop_2 step 24067.

| Exclusive program category | Fast ms | Fast % | Slow ms | Slow % |
|---|---:|---:|---:|---:|
| DMA external-read wait | 5.555 | 25.8 | 58.636 | 46.4 |
| DMA SRAM-write wait | 0.846 | 3.9 | 9.012 | 7.1 |
| SRAM accumulation | 0.738 | 3.4 | 8.904 | 7.1 |
| Other SRAM access | 0.919 | 4.3 | 3.641 | 2.9 |
| Other external access | 0.001 | 0.0 | 0.001 | 0.0 |
| EXEC active | 0.938 | 4.4 | 9.104 | 7.2 |
| MICRO control / handoff | 5.297 | 24.6 | 29.722 | 23.5 |
| Exposed instruction fetch | 6.578 | 30.6 | 6.578 | 5.2 |
| Dispatch / drain | 0.647 | 3.0 | 0.647 | 0.5 |

Program totals: 21.519 / 126.244 ms. UART front is 4.747 / 4.747 ms; completion credit is 0.01654 / 0.01654 ms.

## Findings

1. **DMA and its external reads dominate the active frame.** DMA read+write accounts for 53.6% (67.648 ms). The measured data-bus transactions transfer exactly two bytes each; they include initialization/bias/state copies and one final write, not only weights. The slow frame has 75,098 transactions (150,196 payload bytes), versus 7,048 in the fast frame.
2. **Per-transaction framing is expensive.** A two-byte QPI read uses 24 core cycles for command+address+dummy and 8 for payload, plus 3 select/finish/recovery cycles: 35 controller-active cycles. Thus payload is only 22.9% of controller-active read time. DMA also pays memory/controller handoff and SRAM commit time. This is a transaction-granularity issue in the current controller, not evidence that PSRAM itself requires all this delay.
3. **MICRO instruction sequencing is the second large active-frame component.** Its exclusive control/handoff bucket is 29.722 ms (23.5%). Keeping loops avoids external instruction inflation, but repeated DATA/ADDR/MEM/EXEC/STORE/SYNC dispatch still costs cycles. This bucket must be inspected state by state before changing it; removing mandatory dependencies would be incorrect.
4. **Instruction fetch creates an almost fixed floor.** 5,563 fetches carry 44,504 instruction bytes. Exposed fetch is 6.578–6.578 ms in these two frames: 30.6% of the fast frame, 5.2% of the slow frame. This is largely serial instruction supply, not arbitration contention: measured data-wait-fetch is only about 0.06 ms, and fetch-wait-data is zero in these network cases (both directions are exercised separately by integration tests).
5. **Arithmetic throughput is not the first bottleneck.** EXEC active time is 0.938–9.104 ms (7.2% in the slow frame). Arithmetic widening/pipelining alone cannot remove the larger transfer and sequencing costs.

## Network phases

| Phase | Fast ms | Slow ms |
|---|---:|---:|
| initialization | 0.239 | 0.239 |
| bias setup | 0.426 | 0.426 |
| input u/r | 5.063 | 33.449 |
| recurrent | 5.092 | 66.916 |
| gates | 1.644 | 1.644 |
| input z | 3.110 | 17.487 |
| state update | 5.764 | 5.764 |
| FC | 0.174 | 0.313 |
| fence | 0.001 | 0.001 |
| output store | 0.005 | 0.005 |

Runtime sparse decisions: fast 837 active / 19,451 skipped columns; slow 8,887 active / 11,401 skipped. Counts are tile-column executions, not unique model input features. The slow frame's recurrent phase is 66.916 ms; recurrent state activity explains much of the input-dependent spread.

## What a burst-only change can and cannot do

Even an optimistic accounting exercise that deletes *all* DMA read and SRAM write cycles from the slow frame leaves 58.596 ms. This is not a predicted implementation result; it shows that retaining the rest of the schedule while only accelerating DMA cannot reach 20 ms for this case.
For scale, converting every four independent two-byte reads into an eight-byte read would ideally remove 75% of command/address/dummy cycles. For the slow frame, this is at most 27.035 ms before finite tile boundaries, buffering and handoff effects. It does not remove SRAM commit, internal dispatch or arithmetic. No burst modification is implemented or claimed measured here.

Next investigations in order: DMA framing/burst granularity; MICRO-to-DATA/EXEC command handoff; repeated scalar/state-update instruction supply. Preserve arithmetic order and dependency semantics. Do not start with extra MAC lanes based on this profile.

## All measured frames

| Dataset | Step | UART front ms | Program ms | DMA total ms | MICRO control ms | Exposed fetch ms | EXEC active ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| bishop_0 | 0 | 4.697 | 28.691 | 10.568 | 7.013 | 6.575 | 1.493 |
| bishop_0 | 100 | 4.697 | 52.880 | 24.754 | 12.601 | 6.575 | 3.385 |
| bishop_0 | 25519 | 4.697 | 125.120 | 66.974 | 29.486 | 6.575 | 9.014 |
| bishop_1 | 0 | 4.747 | 25.729 | 8.832 | 6.320 | 6.578 | 1.262 |
| bishop_1 | 100 | 4.747 | 33.958 | 13.669 | 8.208 | 6.578 | 1.907 |
| bishop_1 | 23481 | 4.747 | 118.566 | 63.147 | 27.944 | 6.578 | 8.504 |
| bishop_2 | 0 | 4.747 | 28.692 | 10.557 | 7.022 | 6.578 | 1.492 |
| bishop_2 | 100 | 4.747 | 21.519 | 6.401 | 5.297 | 6.578 | 0.938 |
| bishop_2 | 24067 | 4.747 | 126.244 | 67.648 | 29.722 | 6.578 | 9.104 |
| bishop_3 | 0 | 4.798 | 24.636 | 8.176 | 6.077 | 6.585 | 1.174 |
| bishop_3 | 100 | 4.798 | 31.051 | 11.931 | 7.569 | 6.585 | 1.675 |
| bishop_3 | 20253 | 4.798 | 116.213 | 61.780 | 27.373 | 6.585 | 8.322 |

## Reproduce

```sh
make -f test/Makefile.psram_network build fixtures BUILD=/tmp/acc-bottleneck
python3 scripts/run_psram_network.py --binary /tmp/acc-bottleneck/Vtb_psram_network --profile
python3 scripts/summarize_bottleneck.py
```

Counters live in `test/psram_profile.svh`, enabled only by `+PROFILE`/`--profile`. Per-case `profile.json` and `phases.hex` remain alongside the images; the combined report and RTL hashes are `reports/bottleneck/profile.json`. No synthetic zero-latency memory, altered clock divider or arithmetic shortcut was used.
