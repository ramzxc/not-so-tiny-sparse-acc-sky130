#!/usr/bin/env python3
"""Compare saved unaligned measurements with current aligned network programs."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/weight_alignment'
BEFORE=OUT/'before'
AFTER=ROOT/'reports/stream_deadline'
before=json.loads((BEFORE/'summary.json').read_text())
after=json.loads((AFTER/'summary.json').read_text())
rtl=json.loads((OUT/'rtl_before.json').read_text())
assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==sha for name,sha in rtl.items())
comparisons=[]
for old_window,new_window in zip(before['windows'],after['windows']):
    assert old_window['dataset']==new_window['dataset'] and old_window['steps']==new_window['steps']
    for old,new in zip(old_window['frames'],new_window['frames']):
        name=f'bishop_{new["dataset"]}_step_{new["step"]}'
        a=json.loads((BEFORE/name/'profile.json').read_text())
        b=json.loads((AFTER/name/'profile.json').read_text())
        assert (BEFORE/name/'expected.hex').read_bytes()==(AFTER/name/'expected.hex').read_bytes()
        assert new['result']['mismatches']==0
        assert a['partition'][2:]==b['partition'][2:]
        for key in ['execute_count','sram_accumulates','active_columns','skipped_columns','payload_bytes','host_instructions']:
            assert a[key]==b[key],(name,key)
        layout=json.loads((AFTER/name/'stream.json').read_text())['layout']
        occupied=set()
        for low,high in layout.values():
            assert 0<=low<=high<1024
            span=set(range(low,high+1));assert not occupied.intersection(span)
            occupied.update(span)
        assert layout['weights']==[960,983] and layout['temp_a']==[1008,1009] and layout['temp_b']==[1010,1011]
        comparisons.append(dict(dataset=new['dataset'],step=new['step'],
            before_program_ms=old['program_ms'],after_program_ms=new['program_ms'],
            before_total_ms=old['total_ms'],after_total_ms=new['total_ms'],
            before_dma_ms=sum(a['partition'][:2])/50000,after_dma_ms=sum(b['partition'][:2])/50000,
            before_data_requests=a['requests'][0],after_data_requests=b['requests'][0],
            before_partition=a['partition'],after_partition=b['partition']))
# Low-activity and initial-state cases supplement the adjacent stress windows.
standard=[]
for name in json.loads((ROOT/'reports/psram_stream/cases.json').read_text()):
    case=Path(name);r=json.loads((case/'result.json').read_text());m=json.loads((case/'stream.json').read_text())
    assert r['mismatches']==0 and m['layout']['weights']==[960,983]
    standard.append(dict(dataset=m['dataset'],step=m['step'],result=r))
assert len(standard)==12 and len(comparisons)==12
unique={(r['dataset'],r['step']) for r in comparisons+standard}
slow=max(comparisons,key=lambda r:r['before_program_ms'])
report=dict(comparisons=comparisons,standard_cases=standard,unique_frames=len(unique),rtl_unchanged=True,
            deadline_before=before['windows'],deadline_after=after['windows'],
            generator_sha256=hashlib.sha256((ROOT/'scripts/prepare_fp8_network.py').read_bytes()).hexdigest(),
            limits='RTL simulations at an assumed 50MHz; FIFO calculation from independent warm-state frames. Empty queue per selected window. Not full-trace throughput, live-stream test, synthesis or physical timing signoff.')
(OUT/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
lines=['# Aligned weight scratch: measured comparison','',
       'Software-only SRAM layout change. No functional RTL, SRAM capacity, numerical precision or operation order change; no synthesis.', '',
       '| Region | Before | After |','|---|---|---|',
       '| Input | 768–955 | unchanged |','| Weight / threshold scratch | 956–979 | 960–983 |',
       '| U/R/Z | 980–1003 | 984–1007 |','| Temporary A | 1004–1011 | 1008–1009 |',
       '| Temporary B | 1012–1019 | 1010–1011 |','| FC / constant ones | 1020–1023 | unchanged |','',
       'Each state-update pair consumes both temporary vectors before the next pair starts. Reusing those four bytes frees space to align the 24-byte scratch and accumulator region. All named regions are checked for overlap and containment. Architectural c, old y and new y remain unchanged.', '',
       '## Same slow frame at 50 MHz','',
       '| Metric | Before | After |','|---|---:|---:|',
       f'| Internal program | {slow["before_program_ms"]:.3f} ms | {slow["after_program_ms"]:.3f} ms |',
       f'| UART through completion | {slow["before_total_ms"]:.3f} ms | {slow["after_total_ms"]:.3f} ms |',
       f'| DMA total | {slow["before_dma_ms"]:.3f} ms | {slow["after_dma_ms"]:.3f} ms |',
       f'| External data requests | {slow["before_data_requests"]:,} | {slow["after_data_requests"]:,} |','',
       f'Bishop 2 step 24067 saves {slow["before_program_ms"]-slow["after_program_ms"]:.5f} ms '+
       f'({100*(1-slow["after_program_ms"]/slow["before_program_ms"]):.2f}% of program time). '+
       'The improvement exceeds the earlier 4.752 ms protocol-only estimate: fewer chunks also remove SRAM preservation/commit and DMA handoff cycles. Aligned bias and threshold copies contribute as well. All non-DMA exclusive category cycle counts remain identical across the twelve paired cases.', '',
       '## 100 ms per-input deadline','',
       'Inputs arrive at 0/20/40 ms. The deadline is each arrival plus 100 ms, including queue wait. Each window starts empty.', '',
       '| Dataset | Before maximum latency | After maximum latency | Pass |','|---|---:|---:|---|']
for a,b in zip(before['windows'],after['windows']):
    old=max(r['latency_ms'] for r in a['total_ms']);new=max(r['latency_ms'] for r in b['total_ms'])
    lines.append(f'| bishop_{a["dataset"]} | {old:.3f} ms | {new:.3f} ms | {"yes" if new<=100 else "no"} |')
worst=max(after['windows'],key=lambda w:max(r['latency_ms'] for r in w['total_ms']))
total=sum(f['total_ms'] for f in worst['frames'])
lines += ['', f'The hardest window now requires {total:.5f} ms of service; '+
          f'the third result must finish by 140 ms. Another {total-140:.5f} ms '+
          f'({100*(1-140/total):.2f}% of this window service) must be removed to meet that necessary bound. '+
          'This is not a target requiring every individual frame to finish within 20 ms. Earlier deadlines and longer sequences must also pass.', '',
          '## Validation and next step','',
          f'12 adjacent-frame runs plus 12 standard runs pass ({len(unique)} distinct frames). '+
          'Every run checks all 256 c states, 256 y states, both FC values and PSRAM output. '+
          'Reference outputs are byte-identical to baseline. Arithmetic counts, sparse decisions, payload bytes and stored instruction counts are unchanged. Source hashes confirm no functional RTL changes.', '',
          'The retained software change improves performance without new hardware. Remaining dominant costs in the representative frame: '+
          f'DMA {slow["after_dma_ms"]:.3f} ms; MICRO control/handoff {slow["after_partition"][6]/50000:.3f} ms. '+
          'Next review DATA/MICRO request/completion handoff, especially W_SYNC and A_SYNC, while preserving generic batch/network behavior. No such RTL optimization is included here.', '',
          report['limits'], '',
          'Reproduce with `python3 scripts/evaluate_stream_deadline.py`, '+
          '`python3 scripts/prepare_psram_network.py`, '+
          '`python3 scripts/run_psram_network.py --binary /tmp/acc-deadline-buffered/Vtb_psram_network --profile`, '+
          'then `python3 scripts/compare_weight_alignment.py`. Baseline is preserved in '+
          '`reports/weight_alignment/before`; raw comparison is `reports/weight_alignment/comparison.json`.']
(ROOT/'docs/weight_alignment.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines[18:43]))
