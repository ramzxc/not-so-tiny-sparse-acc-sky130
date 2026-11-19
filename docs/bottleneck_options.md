# Bottleneck options: area-first design review

This is a review, not an implemented optimization. Functional RTL, program images,
clock divider and numeric semantics are unchanged. No synthesis was run.
Calculations use the restored-MICRO twelve-case profile. Values below describe
removed operations/controller cycles, not measured end-to-end speedups.
Reproduce with `python3 scripts/review_bottleneck_options.py`; data is in
`reports/bottleneck/options.json`.

## 1. DMA transfer granularity

**Preferred candidate: bounded, SRAM-row-aware DMA using the existing 64-bit
`mem_itf.write_word`, instead of adding another 64-bit receive cache.**

Current path: for every two bytes, issue QPI read, deliver a 16-bit vector to DMA,
read the destination SRAM row, modify two bytes, write the row, then repeat.

Candidate path:

1. Choose at most four vectors, stopping at the destination 8-byte row boundary,
   the requested length and any required external-memory boundary.
2. If the chunk covers only part of the destination row, read the old row into
   `write_word` first. For a full-row overwrite, no old-row read is required.
3. Issue a continuous QPI read of 2/4/6/8 bytes and merge received bytes into that
   row buffer. Finish the QPI transaction before waiting on SRAM commit.
4. Write one SRAM row, commit, then advance the existing DMA source, destination
   and remaining-vector registers by the chunk length.

This avoids holding CS low while SRAM blocks and avoids a second payload buffer.
The QPI engine already handles reads up to eight bytes for instructions; the
missing work is in DMA/mem_itf request width, direct row-commit control and
completion semantics. The current two-byte data request is hardwired in project.v.
A source address must remain stable for the whole accepted transaction, as today.
Source/destination spans must be validated before the first write, and any PSRAM
burst boundary constraints must be enforced rather than assumed away.

Area is not zero: byte-insertion muxing, a small chunk/progress field and row-copy
states/routing are needed. Reuse the existing row buffer and DMA pointers; do not
introduce a double buffer, new SRAM macro or an independent copy datapath.
The read_data register can retain its ordinary-vector semantics; do not announce
vector completion to the old DMA FSM while silently doing several writes.
This needs an explicit chunk-completion contract between DMA and mem_itf.

The current weight scratch base is **956 = 4 mod 8**. A 16-byte tile becomes
4+8+4-byte chunks, a 24-byte tile 4+8+8+4, and an 8-byte tile 4+4. An aligned,
unrestricted eight-byte-burst estimate overstates the benefit for this layout.
Moving the buffer to 960 would overlap the existing accumulator region beginning
at 980 for a 24-byte tile; changing alignment is not a free address edit.

| Measured frame | Current two-byte DMA reads | Unrestricted <=8-byte reads | Row-bounded reads | Row-bounded QPI service reduction |
|---|---:|---:|---:|---:|
| bishop_2 step 100 | 7,047 | 1,863 | 2,759 | 115,776 cycles = 2.316 ms |
| bishop_2 step 24067 | 75,097 | 18,937 | 27,801 | 1,276,992 cycles = 25.540 ms |

Here service reduction is `(old_transactions - new_transactions) * 27`: each
removed transaction eliminates 24 command/address/dummy cycles and 3 select/
finish/recovery cycles; payload byte count is unchanged. This is exact for the
counterfactual grouping model, before extra implementation overhead, boundary
restrictions and overlap changes. It is not an end-to-end runtime prediction.

For the slow frame, SRAM writes would fall from 75,097 to 27,801, and old-row reads
from 75,097 to 17,945 partial-row reads. These are access counts, not a claimed
cycle saving; the new FSM must establish actual timing. The current SRAM macro
has no byte write mask, so partial rows still require preservation.

A separate 64-bit burst buffer could group without the SRAM row restriction and
save 30.326 ms of QPI service in the slow frame, but then needs extra storage and
still must manage crossing-row commits. Prefer row-buffer reuse first for area.

## 2. MICRO internal command handoff

Keep the generic loops and sparse decisions. Two levels of change are worth
separating:

### Small change: omit redundant address-high commands on proven SRAM paths

For validated auto-DMA + SRAM-input runs, W_HI and A_HI repeatedly set DATA's
address high part to zero. The preceding input/accumulator access or DMA destination
setup has already established zero. This invariant covers batched execution too
when inputs are SRAM; external-input and other modes need the original path.

Skip those states by conditional transitions using existing mode flags. No new
cache, pointer or data register is inherently needed, though the state transition
logic changes. Keep SYNC and operand/result handoff waits.

Measured eligible occurrences on the current workload:

- Fast frame: 12,298 issue cycles, or **0.246 ms**.
- Slow frame: 148,398 issue cycles, or **2.968 ms**.

This counts one-cycle states that can be omitted under the invariant. It is a
modest candidate, not a way to recover all 29.72 ms of MICRO control time. Validate
first/subsequent group, odd/even column, all-zero columns, batch transitions,
external-input fallbacks, reset and generic non-DMA behavior.

### Larger change: combine address/mode setup with the SRAM operation

A compact SRAM-load command could replace DATA + ADDR_LO + ADDR_HI + MEM. A
compact result-to-SRAM command could replace STORE + ADDR_LO + ADDR_HI + MEM.
Use a 9-bit two-byte-aligned SRAM vector address; keep arbitrary network shapes,
activations, external-memory operations and batch support. Define and check the
encoding before implementation; current NOP/SYNC encodings must stay compatible.

Reuse DATA's base_addr/mode/write_buffer and its existing SEND/WAIT/DELIVER
lifetime. This needs decoder/mux/control changes, even if no extra payload
register is required. An internal MICRO-only form can precede a public stored-ISA
extension, but only the latter reduces external instruction fetch.

Replacing both four-command setup sequences with one each removes six issue
cycles per active output group in the current batch-1 schedule: **0.738 ms** in
the fast frame and **8.904 ms** in the slow frame. This excludes possible input
setup reductions and does not remove memory or compute latency. It supersedes,
not adds to, the redundant-high-word saving above. Batch >1 has a different
reuse pattern and must be evaluated separately.

Do not simply delete EXEC_SYNC: DATA's result_valid means that some result is
held, not that the latest EXEC finished. STORE could otherwise capture the
previous operation. Likewise DELIVER is when EXEC captures a new operand; ready
shortcuts that bypass it can consume stale data.

## 3. Instruction supply

### First reuse compact SRAM operations, rather than adding a cache

The stored program contains ordinary scalar/state-update operations as well as
MICRO setup. Both extreme frames have 22,252 words. A static pattern scan finds
4,994 SRAM operand-load/result-store sequences that could use a compact opcode,
removing **9,541 words**, leaving **12,711** (about 43% smaller).

At the existing four-word fetch size, the corresponding QPI service reduction
is **140,723 cycles = 2.814 ms**. This counts framing and payload cycles of the
hypothetically shorter program; changed dependency stalls and fetch alignment
still require RTL simulation. Ordinary stores here must remain overwrite stores,
whereas MICRO accumulation stores must still round and accumulate in SRAM.
A shared compact command family must represent both semantics explicitly.

### Defer a second prefetch buffer

The current four-word buffer is already small. A second one adds at least 64
payload bits plus valid/address/control state and scheduling complexity. Prefetch
also shares the weight bus and can delay a later data request once accepted.
It may hide some of the 6.58 ms fetch component, not eliminate it for free.

Aligning each long MICRO_RUN to the final slot of a fetch block can expose an
opportunity to fetch the next block during execution without a new buffer.
There are 160 nonempty MICRO runs in the generated program: even hiding an
additional full roughly-60-cycle fetch after every one is only about **0.192 ms**
of gross opportunity, before padding words and overlap already present. It does
not address most scalar/state-update fetches. This is a secondary software
experiment, not the primary solution.

## Recommendation and validation gates

Review/implementation order:

1. Row-bounded DMA through the existing SRAM row buffer: largest likely benefit
   per added state/storage; preserve the current memory map and generic tails.
2. Small proven-SRAM high-word omission, or proceed to compact operations if
   its larger RTL change is acceptable. Keep MICRO loops and required barriers.
3. Reuse compact operations in the stored program; leave double buffering and
   wider datapaths for a later, measured need.

Do not sum the numbers above into a promised final latency. They use different
accounting boundaries; the two MICRO alternatives overlap; DMA changes may
alter arbitration and handoff. Even making all existing DMA read/write cycles
free leaves 58.596 ms in the slow frame under the unchanged remaining schedule.
These local candidates do not establish sustained 20 ms service at 50 MHz.

Before accepting a DMA implementation, verify arbitrary even SRAM destinations,
1..255 vector counts, partial head/tail neighbors, source/destination bounds,
reset during reads/commits, and instruction/data ownership. Before accepting a
compact operation, check old-ISA compatibility, stale-result/operand hazards,
FP8 rounding order, sparse signed zeros and NaNs, dense mode and batch behavior.
Finally rerun the same twelve full EGRU+FC frames and compare bit-exact output and
separate profile categories. Only run synthesis if explicitly requested.
