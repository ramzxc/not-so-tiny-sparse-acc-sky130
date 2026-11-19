#!/usr/bin/env python3
"""Collect reproducible functional/area evidence for the transport-only stage."""
import hashlib,json,re,shutil
from pathlib import Path
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/psram_stream'
unit_paths=[ROOT/'test/results.xml',Path('/tmp/acc-psram-arbiter/results.xml'),Path('/tmp/acc-micro/results.xml'),Path('/tmp/acc-dma/results.xml'),Path('/tmp/acc-mem-itf/results.xml'),Path('/tmp/acc-fp8-exec/results.xml')]
checks=[]
for p in unit_paths:
 tree=ET.parse(p);cases=list(tree.iter('testcase'));assert cases and not list(tree.iter('failure')) and not list(tree.iter('error')),p
 checks.append(dict(path=str(p),passed=len(cases)));dest=OUT/'unit_results';dest.mkdir(exist_ok=True);shutil.copy2(p,dest/f'{p.parent.name}_{p.name}')
rows=[]
for name in json.loads((OUT/'cases.json').read_text()):
 case=Path(name);m=json.loads((case/'stream.json').read_text());r=json.loads((case/'result.json').read_text())
 assert r['mismatches']==0 and r['fetches']==(m['program_words']+3)//4 and r['max_cs_low_ns']<=3000
 rows.append(dict(dataset=m['dataset'],step=m['step'],**r,total_ms_50mhz=r['cycles']/50000,program_ms_50mhz=r['core_cycles']/50000,
                  image_sha256=hashlib.sha256((case/'psram.hex').read_bytes()).hexdigest()))
area={}
for name,folder in [('baseline','/tmp/acc-psram-area-baseline-exact'),('initial','/tmp/acc-psram-area-current'),('final','/tmp/acc-psram-area-final')]:
 p=Path(folder)/'reports/area.rpt'
 if p.exists():
  s=p.read_text();total=float(re.search(r'Total cell area:\s+([\d.]+)',s)[1]);macro=float(re.search(r'Macro/Black Box area:\s+([\d.]+)',s)[1])
  area[name]=dict(total_um2=total,sram_um2=macro,logic_um2=total-macro)
  dst=OUT/'synthesis'/name;dst.mkdir(parents=True,exist_ok=True)
  for src in p.parent.glob('*.rpt'):shutil.copy2(src,dst/src.name)
files=list((ROOT/'src/rtl').rglob('*'))+[ROOT/'src/wrapper/project.v',ROOT/'src/sources.f',ROOT/'test/tb_psram_stream.sv',ROOT/'test/tb_psram_network.sv',ROOT/'test/qspi_psram_model.sv']
summary=dict(scope='UART input + sequential PSRAM program/weights/output; MICRO retained; no weight cache; single 64-bit instruction buffer.',unit_tests=checks,full_network_cases=rows,area=area,
 limitations='Selected warm-started FP8 cases, not accuracy evaluation. Total time includes input UART and completion credit, program time includes state setup, instruction fetch, EGRU+FC and PSRAM result write. MCU provisioning and UART numerical result output are not measured. 50MHz is functional cycle conversion, not timing signoff. Synthesis is core-only, same libraries/20ns constraint, fixed SRAM; historical baseline reconstructed from saved pre-change transport files, MICRO retained.',
 source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()})
(OUT/'validation.json').write_text(json.dumps(summary,indent=2)+'\n')
lines=['# PSRAM stream stage validation','',
'UART supplies input data; PSRAM supplies stored commands and weights, and receives numerical output. MICRO remains active. One 64-bit instruction buffer, no weight cache/second prefetch buffer. See [interface](psram_stream.md).','',
f"Passed {sum(c['passed'] for c in checks)} cocotb tests across {len(checks)} suites, plus the native data-control post-increment test. Twelve full Bishop cases match all 256 c states, 256 y states, both FC outputs, and both output bytes in external PSRAM. Generic batch 1/3/4, both fetch/data wait directions, random ownership/backpressure, bounds, replay, framing and reset are covered.",
'', '| Dataset | Step | UART input through completion (ms at 50 MHz) | Program execution (ms) |', '|---|---:|---:|---:|']
for r in rows:lines.append(f"| bishop_{r['dataset']} | {r['step']} | {r['total_ms_50mhz']:.3f} | {r['program_ms_50mhz']:.3f} |")
lines+=['','Program execution includes state initialization, instruction fetch, EGRU/FC and PSRAM output. It is not the old ideal-feed core-only boundary. The input buffer is filled exclusively over UART; no input Flash/PSRAM DMA remains in these programs. All observed physical reads are bounded; maximum CS-low time is 1.14 us at 50 MHz. These are selected RTL samples, not a full-dataset timing average or task-accuracy result.','',
'## Synthesis area','', '| Revision | Logic area (um²) | SRAM area (um²) | Total cell area (um²) |','|---|---:|---:|---:|']
for k,a in area.items():lines.append(f"| {k} | {a['logic_um2']:.1f} | {a['sram_um2']:.1f} | {a['total_um2']:.1f} |")
if 'final' in area:
 b,f=area['baseline'],area['final'];lines+=['',f"Final vs baseline: logic {100*(f['logic_um2']/b['logic_um2']-1):+.2f}%, total {100*(f['total_um2']/b['total_um2']-1):+.2f}%. This stage adds autonomous program fetch/configuration; it does not yet remove MICRO. The initial version was reduced by reusing live pointer/count registers, borrowing the UART word and bus owner's address/write data, and simplifying the 64-bit buffer loading/selection."]
lines+=['','These are DC core-only mapped-cell comparisons under the same libraries, hierarchy constraints and 20 ns clock target. SRAM is unchanged. Baseline uses the saved pre-change project/memory/QSPI datapath and the earlier external address limit, with the common current compute blocks. The baseline UART receiver also restores the pre-change fault-port interface. No placement, routing or timing closure is claimed; timing constraints include historical absolute I/O delays, so these results must not be read as 50 MHz signoff.','',
'Artifacts: `reports/psram_stream/validation.json`, per-case images/expected outputs/logs, unit XML copies, and `synthesis/{baseline,initial,final}` reports. Reproduce functional tests with `make -C test` and `make -f test/Makefile.psram_network`; reproduce area with `scripts/measure_stream_area.tcl` in fresh output directories.']
(ROOT/'docs/psram_stream_validation.md').write_text('\n'.join(lines)+'\n')
print(f'{len(rows)} full-network cases; {sum(c["passed"] for c in checks)} cocotb tests; area revisions {list(area)}')
