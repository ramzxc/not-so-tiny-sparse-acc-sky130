#!/usr/bin/env python3
"""Audit an isolated ICC2 area/routability run and draw placed-cell extents."""
import argparse
import hashlib
import html
import json
import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('run',type=Path);args=parser.parse_args()
run=args.run.resolve();audit=run/'audit'
manifest=json.loads((run/'manifest.json').read_text())
assert all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in manifest['source_hashes'].items())
assert 'final_clean.design' in (audit/'geometry.txt').read_text()
assert 'FIT_AUDIT_COMPLETE' in (run/'audit_final.log').read_text()
util=(audit/'utilization.rpt').read_text();qor=(audit/'qor.rpt').read_text();area=(run/'synthesis/reports/area.rpt').read_text()
value=lambda pattern,s:float(re.search(pattern,s)[1])
ratio=value(r'Utilization Ratio:\s+([\d.]+)',util)
capacity=value(r'Total Capacity Area:\s+([\d.]+)',util)
logic=value(r'Total Area of cells:\s+([\d.]+)',util)
synth=value(r'Total cell area:\s+([\d.]+)',area)
sram=value(r'Macro/Black Box area:\s+([\d.]+)',area)
netlist=value(r'Cell Area \(netlist\):\s+([\d.]+)',qor)
physical=value(r'Cell Area \(netlist and physical only\):\s+([\d.]+)',qor)
routes=(audit/'routes.rpt').read_text()
for pattern in [r'Total number of open nets = (\d+)',r'Total number of DRCs = (\d+)',r'Total number of antenna violations = (\d+)']:
    assert value(pattern,routes)==0
assert 'TOTAL 0 Violations.' in (audit/'legality.rpt').read_text()
assert 'No errors found.' in (audit/'pg_drc.rpt').read_text()
floating=re.findall(r'Number of floating [\w /]+:\s+(\d+)',(audit/'pg.rpt').read_text())
assert len(floating)==14 and all(int(v)==0 for v in floating)
cells=[]
for line in (audit/'cells.tsv').read_text().splitlines()[1:]:
    name,ref,bbox,status=line.split('\t')
    rect=list(map(float,re.findall(r'-?\d+\.\d+',bbox)))
    assert len(rect)==4
    assert rect[0]>=-.001 and rect[1]>=-.001 and rect[2]<=1367.121 and rect[3]<=214.881,(name,rect)
    assert status in ['placed','fixed','legalized','application_fixed'],(name,status)
    cells.append(dict(name=name,ref=ref,bbox=rect,status=status))
assert sum(c['ref']=='tt_sram_1rw_64x128_buffered_sky130' for c in cells)==1
assert sum(c['name'].startswith('TT_FIT_ANT_') for c in cells)==3
result=dict(run=str(run),checkpoint=str(run/'pnr/acc_hard_macro.ndm')+':acc_hard_macro/final_clean.design',
            tile_um=[1378.16,225.76],core_um=[1367.12,214.88],wrapper_origin_um=[5.52,5.44],
            sram_origin_core_um=[514.785,.265],sram_lef_size_um=[842.335,214.355],
            synthesis_logic_um2=synth-sram,synthesis_sram_um2=sram,synthesis_total_um2=synth,
            placed_logic_um2=logic,placement_capacity_um2=capacity,placed_utilization=ratio,
            netlist_area_um2=netlist,area_including_physical_only_um2=physical,
            physical_instances=len(cells),manual_antenna_diodes=3,removed_unused_pg_rail_fragments=77,
            legality_violations=0,route_drc=0,route_opens=0,antenna_violations=0,pg_drc=0,all_pg_floating_counts=0,
            rtl_unchanged=True,
            limits='Standalone core area/routability check with fixed TT 8x2 envelope. ICC2 community technology/nominal RC checks, not merged-GDS foundry DRC/LVS, wrapper integration or timing signoff. SRAM Liberty is analytical. 20ns IO delays retained with 20ns clock; IO timing fails. Clock-group setup slack +4.45ns nominal only.')
(run/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
colors={'exec':'#388b62','sequencer':'#d28b35','frontend':'#417cb5','itf':'#926db5'}
svg=['<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -50 1405 325">',
     '<rect x="-12" y="-50" width="1405" height="325" fill="white"/>',
     '<text x="0" y="-25" font-family="sans-serif" font-size="19">Final placed cells — TT 8 × 2 envelope, right-side 1 KiB SRAM</text>',
     '<rect width="1378.16" height="225.76" fill="#f4f6f8" stroke="#172c43" stroke-width="1.5"/>',
     '<rect x="5.52" y="5.44" width="1367.12" height="214.88" fill="none" stroke="#688096" stroke-dasharray="4 3"/>']
for c in cells:
    if c['ref'].startswith('tt_sram') or '__fill_' in c['ref']:continue
    x1,y1,x2,y2=c['bbox'];color=colors.get(c['name'].split('/')[0],'#91a0ac')
    svg.append(f'<rect x="{x1+5.52:.3f}" y="{225.76-y2-5.44:.3f}" width="{x2-x1:.3f}" height="{y2-y1:.3f}" fill="{color}"/>')
svg += ['<rect x="520.305" y="5.7" width="842.335" height="214.355" fill="#dbe4f2" stroke="#254a88"/>',
        '<text x="780" y="105" font-family="sans-serif" font-size="24">1 KiB buffered SRAM</text>',
        '<text x="780" y="135" font-family="sans-serif" font-size="17">842.335 × 214.355 µm · N / R0</text>',
        f'<text x="0" y="249" font-family="sans-serif" font-size="16">Standard-cell utilization: {ratio*100:.2f}% · Legality / route / antenna / PG checks: 0 errors</text>',
        '<text x="0" y="271" font-family="sans-serif" font-size="13">Cell extents shown; fillers omitted. Routes checked separately. Not a merged-GDS signoff image.</text>','</svg>']
(run/'floorplan.svg').write_text('\n'.join(svg)+'\n')
rel=run.relative_to(ROOT)
lines=['# Buffered 1 KiB SRAM: synthesis and physical fit','',
       '**Result: the current core fits the TT 8×2 envelope and completes placement, CTS, routing and filler insertion.** Final ICC2 legality, route DRC, opens, antenna and PG checks are zero. This is an area/routability pass, not tapeout signoff.', '',
       f'Run: `{rel}`. Final block: `pnr/acc_hard_macro.ndm:acc_hard_macro/final_clean.design` under that run. Old design libraries and synthesis outputs were preserved; no functional RTL changes.', '',
       '| Metric | Value |','|---|---:|',
       '| TT die footprint | 1378.16 × 225.76 µm |','| Standalone core boundary | 1367.12 × 214.88 µm |',
       f'| Synthesized logic | {synth-sram:,.2f} µm² |',f'| SRAM Liberty area | {sram:,.2f} µm² |',
       f'| Synthesized total | {synth:,.2f} µm² |',f'| Final standard-cell area reported for utilization | {logic:,.2f} µm² |',
       f'| Available standard-cell placement capacity | {capacity:,.2f} µm² |',
       f'| Final standard-cell utilization | {ratio*100:.2f}% |',f'| Final netlist area, including SRAM | {netlist:,.2f} µm² |',
       f'| Area including physical-only cells/fillers | {physical:,.2f} µm² |','',
       'Utilization excludes the macro and placement keepouts. The remaining percentage is not a promise of equally large future logic growth: routing, timing, tap/endcap fragmentation and added fanout still matter. Filler area is not functional logic consumption.', '',
       'The SRAM remains at core origin (514.785, 0.265), tile origin (520.305, 5.705), R0/N. Actual LEF/GDS outline is 842.335 × 214.355 µm. ICC2 reported cell bboxes can include pin/keepout extents; the audit checks those extents as well as all standard-cell extents against the core boundary.', '',
       '## Physical fixes in this isolated run','',
       '- Built the new buffered SRAM NDM using its current LEF and compiled Liberty DB.',
       '- Updated stale 512B macro selectors for LI blockage and antenna properties; regenerated gate-area bounds from the new SRAM LVS SPICE.',
       '- Preserved right-side SRAM placement and left-side supply feeds. Inserted taps/endcaps, optimized placement, synthesized clocks and routed.',
       '- Added three small diode_2 antenna cells: two on the SRAM constant-input net and one on macro_data[15]. They do not change logical behavior. They are included in the final area.',
       '- Removed 77 isolated M1 PG rail fragments in the unused right keepout. All floating-wire, floating-via, floating-cell, floating-macro and floating-terminal counts are now zero.',
       '- Initial scripts stopped on remaining antenna violations rather than waiving them. Final repair, cleanup and fresh audit are preserved separately.', '',
       '## Validation and remaining limits','',
       'Final saved block was reopened; current antenna rules were explicitly reloaded before audit (ICC2 does not retain these rules merely by opening the saved block). All route/antenna/PG/legality counts pass, and source hashes confirm unchanged functional RTL.', '',
       'The run targets a 20 ns clock but retains historical 20 ns input/output delays. IO timing is therefore not closed; nominal clock-group setup slack is +4.45 ns, not a board/PVT guarantee. SRAM timing is analytical. No merged-GDS foundry DRC/LVS, full wrapper PnR, gate-level equivalence or multi-corner timing signoff was performed.', '',
       f'Artifacts: [placement preview](../{rel}/floorplan.svg), [summary](../{rel}/summary.json), '+
       f'[final utilization](../{rel}/audit/utilization.rpt), [route/antenna checks](../{rel}/audit/routes.rpt), '+
       f'[PG connectivity](../{rel}/audit/pg.rpt), [legality](../{rel}/audit/legality.rpt).', '',
       'Reproduction scripts in the run: `synth.tcl`, `lm.tcl`, `pnr.tcl`, `finish.tcl`, `finish2.tcl`, `cleanup.tcl`, `audit.tcl`. Source/config snapshots and hashes are retained. '+
       'Final DEF is `audit/layout.def`; the saved NDM includes intermediate checkpoints. No submission artifacts or syn/LATEST pointer were replaced.']
(ROOT/'docs/physical_fit.md').write_text('\n'.join(lines)+'\n')
print(json.dumps(result,indent=2))
