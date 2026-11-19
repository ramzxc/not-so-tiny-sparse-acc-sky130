#!/usr/bin/env python3
"""Read saved staged simulation/synthesis evidence without running tools."""
import json,re,hashlib,shutil
from pathlib import Path
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/optimization_stages'
configs=[('s0_baseline','Baseline','s0'),('s1_row_dma','Row DMA','s1'),('s2a_skip_high','Skip redundant high','s2a'),('s2b_compact_micro','Compact MICRO commands','s2b'),('s3_compact_program','Compact stored program','s3')]
rows=[]
for name,label,run in configs:
 stage=OUT/name;measure=json.loads((stage/'measurements.json').read_text());assert len(measure)==12
 for r in measure:
  assert r['result']['mismatches']==0 and r['result']['max_cs_low_ns']<=3000
 reports=Path('/tmp')/f'acc-opt-{run}'/'reports';area=(reports/'area.rpt').read_text()
 total=float(re.search(r'Total cell area:\s+([\d.]+)',area)[1]);macro=float(re.search(r'Macro/Black Box area:\s+([\d.]+)',area)[1])
 dst=stage/'synthesis';dst.mkdir(exist_ok=True)
 for p in reports.glob('*.rpt'):shutil.copy2(p,dst/p.name)
 register_slack=None
 sta=Path('/tmp')/f'acc-opt-{run}-sta/reports/register_timing.rpt'
 if sta.exists():
  shutil.copy2(sta,dst/sta.name)
  register_slack=min(float(x) for x in re.findall(r'slack \((?:MET|VIOLATED)\)\s+(-?[\d.]+)',sta.read_text()))
 rows.append(dict(stage=name,label=label,total_um2=total,sram_um2=macro,logic_um2=total-macro,
    program_min_ms=min(x['result']['core_cycles'] for x in measure)/50000,
    program_max_ms=max(x['result']['core_cycles'] for x in measure)/50000,
    total_min_ms=min(x['result']['cycles'] for x in measure)/50000,
    total_max_ms=max(x['result']['cycles'] for x in measure)/50000,
    register_slack_ns=register_slack,measurements=measure))
checks=[]
for path in [ROOT/'test/results.xml',Path('/tmp/acc-opt-s1-dma/results.xml'),Path('/tmp/acc-opt-s2b-micro/results.xml'),Path('/tmp/acc-opt-final-mem/results.xml'),Path('/tmp/acc-opt-final-arbiter/results.xml')]:
 tree=ET.parse(path);assert not list(tree.iter('failure')) and not list(tree.iter('error'))
 cases=list(tree.iter('testcase'));assert cases
 checks.append(dict(path=str(path),passed=len(cases)))
 dst=OUT/'validation';dst.mkdir(exist_ok=True);shutil.copy2(path,dst/f'{path.parent.name}_{path.name}')
# Check that final RTL differs from synthesized stage 3 only in comments/whitespace.
def normalize(s):return re.sub(r'\s+','',re.sub(r'/\*.*?\*/|//[^\n]*','',s,flags=re.S))
final=OUT/'s3_compact_program/src'
for p in final.rglob('*'):
 if p.is_file() and p.suffix in ('.v','.sv','.vh'):
  assert normalize(p.read_text())==normalize((ROOT/'src'/p.relative_to(final)).read_text()),p
b=rows[0];f=rows[-1];core_area=1367.12*214.88;free=core_area-f['sram_um2']
summary=dict(stages=rows,unit_tests=checks,python_compiler_tests=4,native_postincrement_pass=True,
    core_rectangle_um2=core_area,unblocked_logic_area_um2=free,
    final_nominal_logic_occupancy=f['logic_um2']/free,
    limitations='Mapped cell area, fixed 1KiB SRAM, TT20ns, same libraries/hierarchy/SDC. No P&R signoff. Existing input/output delays each 20ns overconstrain a 20ns IO path. Register timing reported separately. Current macro placement y19.135+height214.355 exceeds local 8x2 die height225.76. No floorplan/PDN edits.',
    current_rtl_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'src/rtl').rglob('*') if p.is_file()})
(OUT/'comparison.json').write_text(json.dumps(summary,indent=2)+'\n')
lines=['# Staged optimization: area and complete-network performance','',
'User-authorized staged synthesis and implementation. All five revisions are preserved under `reports/optimization_stages/`, including source/test/script snapshots, measured cases and synthesis reports. No commits, submission artifacts, floorplan or PDN changes were made. Final functional RTL matches stage 3; subsequent source edits only clarify comments.','',
'## Results','',
'All stages match the reference for 256 c states, 256 y states, both FC values and final PSRAM output in the same twelve Bishop frames. Times below are RTL cycles converted at 50 MHz; program time includes warm-state setup, instruction fetch, all EGRU/FC operations and output store. Total additionally includes UART input/credits and completion credit. Initial CONFIG and MCU provisioning are excluded.','',
'| Stage | Logic area µm² | SRAM area µm² | Total area µm² | Program ms, min–max | UART-to-completion ms, min–max |',
'|---|---:|---:|---:|---:|---:|']
for r in rows:lines.append(f"| {r['label']} | {r['logic_um2']:,.1f} | {r['sram_um2']:,.1f} | {r['total_um2']:,.1f} | {r['program_min_ms']:.3f}–{r['program_max_ms']:.3f} | {r['total_min_ms']:.3f}–{r['total_max_ms']:.3f} |")
lines+=['',f"Final vs baseline: logic **{100*(f['logic_um2']/b['logic_um2']-1):+.2f}%** ({f['logic_um2']-b['logic_um2']:+.1f} µm²), total **{100*(f['total_um2']/b['total_um2']-1):+.2f}%**. Worst selected program time decreases **{100*(1-f['program_max_ms']/b['program_max_ms']):.2f}%**. The SRAM is unchanged. Stage 3 has the same RTL and independently reproduced mapped area as stage 2b; its gain is software instruction compaction.",'',
'| Increment | Additional logic µm² | Reduction of worst program time ms |','|---|---:|---:|']
for prev,r in zip(rows,rows[1:]):lines.append(f"| {r['label']} | {r['logic_um2']-prev['logic_um2']:+.1f} | {prev['program_max_ms']-r['program_max_ms']:.3f} |")
lines+=['','## Interpretation / practical stopping point','',
'Every tested increment improves throughput with a small mapped-area increase, and stored-program compaction costs no further hardware area. No area/performance knee was reached within these candidates. Keep the final implementation as the tested candidate; retain the snapshots if a narrower change is preferred. This is not proof that a larger prefetch cache or extra compute lanes would be worthwhile; neither was added.',
'',f"The final worst selected frame is still {f['program_max_ms']:.3f} ms before UART input. The fastest total is {f['total_min_ms']:.3f} ms, but that does **not** establish sustained 20 ms input service across the data. These are selected frames, not a full-trace mean/worst-case guarantee. More work remains for the original continuous-real-time target.",'',
'## Physical and timing limits','',
'- DC uses the same SKY130 HD and 1 KiB SRAM libraries, hierarchy retention and 20 ns clock for every stage. Reports are mapped-cell comparisons, not placed/routed area.',
f"- The local core rectangle is {core_area:,.1f} µm². Subtracting the macro gives {free:,.1f} µm²; final logic occupies about {100*f['logic_um2']/free:.1f}% of that nominal remainder. This is only an area screen: routing, halos, PDN, placement fragmentation and later buffers are excluded.",
'- There is a pre-existing concrete floorplan issue: the macro LEF is 840.455 × 214.355 µm, while config places its lower-left y at 19.135 µm. Its top is 233.490 µm, exceeding the local 8×2 die height 225.760 µm. Fixing placement/PDN is separate work; the placement was not changed here. Mapped area alone cannot decide the final tapeout limit.',
'- Overall reported setup slack is negative because existing input and output delays are each 20 ns while the comparison clock is 20 ns. The worst path is reset input to output enable; those numbers do not establish the internal Fmax. Constraints were held identical to keep the area comparison fair. Board I/O/reset timing still needs a real constraint/signoff pass.',
f"- Read-only register-to-register timing on saved mapped netlists gives minimum setup slack {b['register_slack_ns']} ns (baseline) and {f['register_slack_ns']} ns (final) at 20 ns. This is pre-layout, ideal-clock, TT analysis; it is useful internal evidence but not a routed/PVT/board 50 MHz guarantee.",'',
'## Implemented behavior','',
'1. DMA copies 1..4 vectors per SRAM-row-bounded QPI read, merges partial rows into the existing write_word buffer and commits once per chunk. Full rows avoid the old-row read. Source/count/destination stay stable until commit; complete span checking, exclusive ownership, reset and errors remain. No extra payload buffer or SRAM macro was added.',
'2. Auto-DMA/SRAM-input MICRO skips redundant high-address commands and then uses compact SRAM weight-load/result-accumulate operations. Other paths retain their generic ordinary instruction behavior; batch support and sparse column skipping remain.',
'3. The stored-program compiler folds safe contiguous SRAM setup sequences, keeps every dependency fence and arithmetic operation, and invalidates address knowledge after MICRO_RUN. The typical program decreases from 22,252 to 12,711 words; four-word fetch requests decrease from 5,563 to 3,178.',
'- Canonical FFFF SYNC is preserved. Former noncanonical opcode-111 SYNC aliases E000..F7FF are repurposed for compact SRAM operations. This encoding extension must be reflected in tools; see [interface](psram_stream.md). UART CONFIG framing and the 16-bit program count are unchanged.',
'- Boot must select PSRAM linear burst mode before releasing the bus. Wrapped mode is not a substitute for arbitrary-address linear transfers. Maximum observed CS-low remains 1.14 µs at 50 MHz in every stage.','',
'## Validation','',
f"Final evidence includes {sum(c['passed'] for c in checks)} cocotb tests across integration, MICRO, DMA, memory and arbiter suites; four compiler unit tests; native DATA post-increment verification; and twelve complete-network comparisons at every stage. Integration cases cover generic batch 1/3/4; sequencer tests include batch 128 and external-input fallbacks. Added cases cover all compact scalar subcodes, signed zero/NaN, 255-vector copies, unaligned sources, every SRAM vector slot, partial-row neighbor preservation, last SRAM row, reset before commit, backpressure and invalid spans.",
'','The expanded integration test initially exposed an oracle mistake that converted a dense negative-zero product to positive zero. The oracle was corrected to the existing overwrite-MUL semantics; no arithmetic RTL was changed. Final lint passes with only the existing 65-bit macro-model X-width warning.','',
'## Reproduce and inspect','',
'```sh','make -C test','make -C test -f Makefile.micro','make -C test -f Makefile.dma','make -C test -f Makefile.mem_itf','make -C test -f Makefile.arbiter','make -C test -f Makefile.data_ctrl','python3 -m unittest discover -s test -p test_compact_sram.py','make -f test/Makefile.psram_network build fixtures','python3 scripts/run_psram_network.py --profile','python3 scripts/summarize_optimization_stages.py','```','',
'Synthesis was invoked explicitly per stage using `ACC_RTL_SNAPSHOT` and a fresh `ACC_MANUAL_OUT` with `scripts/measure_stream_area.tcl`. Normal tests and report scripts do not launch synthesis. Stage snapshots and `comparison.json` retain exact evidence. `register_timing.rpt` comes from a read-only DDC inspection, not another compile.']
(ROOT/'docs/optimization_stages.md').write_text('\n'.join(lines)+'\n')
for r in rows:print(r['stage'],round(r['logic_um2'],1),round(r['total_um2'],1),round(r['program_max_ms'],3),r['register_slack_ns'])
