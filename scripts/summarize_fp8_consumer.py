#!/usr/bin/env python3
"""Separate input command supply, internal processing, and Flash result emission."""
import hashlib,json
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/fp8_full'
BASE=[272712,273630,273630,274740]
rows=[];datasets=[];combined=[]
def response(cycles,mhz,back=False):
    service=cycles/(mhz*1000)+(6+455/(mhz*1000) if back else 0)
    cumulative=np.cumsum(service);arrival=np.arange(len(service))*20
    return cumulative+np.maximum.accumulate(arrival-np.r_[0,cumulative[:-1]])-arrival
def deadline_clock(cycles,back):
    lo,hi=1.,1000.
    for _ in range(40):
        mid=(lo+hi)/2
        if response(cycles,mid,back).max()<=100:hi=mid
        else:lo=mid
    return hi
paths=json.loads((OUT/'consumer_cases.json').read_text())+json.loads((OUT/'consumer_holdout_cases.json').read_text())
for ds in range(4):
    a=np.genfromtxt(OUT/f'bishop_{ds}/activity.csv',delimiter=',',names=True,dtype=int)
    prediction=BASE[ds]+27648*a['input']+23616*a['previous']+177*a['output']
    for path in paths:
        case=Path(path);meta=json.loads((case/'metadata.json').read_text())
        if meta['dataset']!=ds:continue
        r=json.loads((case/'result.json').read_text());t=meta['step']
        assert r['mismatches']==0 and r['flash_programs']==2
        assert r['compute_cycles']==prediction[t] and r['flash_export_cycles']==300455
        assert sum(r['phase_cycles'])==r['cycles']
        rows.append(dict(dataset=ds,step=t,**r))
        if (case/'uart87_export.json').exists():
            u=json.loads((case/'uart87_export.json').read_text())
            assert u['mismatches']==0 and u['flash_programs']==2
            # Marginal command-supply overhead, not independent UART wire time.
            front=u['cycles']-r['cycles']
            combined.append(dict(dataset=ds,step=t,front_extra_ms=front/50000,core_ms=r['compute_cycles']/50000,
                                 back_ms=r['flash_export_cycles']/50000,total_ms=u['cycles']/50000,
                                 uart_core_ms=u['compute_cycles']/50000,uart_export_ms=u['flash_export_cycles']/50000))
    datasets.append(dict(dataset=ds,steps=len(a),core_mean_ms=float(prediction.mean()/50000),core_max_ms=float(prediction.max()/50000),
                         core_only_average_rate_mhz=float(prediction.mean()/20000),
                         core_only_20percent_margin_mhz=float(prediction.mean()/16000),
                         core_only_100ms_deadline_mhz=deadline_clock(prediction,False),
                         core_flash_100ms_deadline_mhz=deadline_clock(prediction,True)))
assert len(rows)==20 and len(combined)==3
summary=dict(clock_hz=50000000,core_feed='Ideal commands injected at existing FIFO input; real FIFO/MICRO/DMA/EXEC/SRAM/QSPI remain; not an implemented chip mode.',
             input_boundary='Input already in external Flash; internal input DMA included. PC-to-input-storage path not implemented/measured.',
             output_boundary='Two FP8 FC bytes committed to pre-erased external Flash; no subsequent PC work.',
             flash_program_time_ms=3,flash_programs_per_frame=2,flash_source='https://www.mouser.com/datasheet/2/949/Winbond_Electronics_Corporation_09_06_2024_W25Q128-3501276.pdf',
             cycle_model=dict(base_by_dataset=BASE,input_active_coefficient=27648,previous_active_coefficient=23616,output_active_coefficient=177,calibration_cases=12,held_out_cases=8,max_validation_error_cycles=0),
             model_limit='Full-dataset timing and queue results are model projections, not full-sequence RTL. Continuous 20 ms arrivals; no inter-trial gaps; omit trial-reset command cost and input ingress. Flash max tPP fixed at 3 ms while logic cycles scale. No physical timing claim.',
             measured_core_cases=rows,measured_decomposition=combined,projected_datasets=datasets)
files=[ROOT/'test/tb_fp8_consumer.sv',ROOT/'scripts/prepare_fp8_network.py',ROOT/'scripts/summarize_fp8_consumer.py']+list((ROOT/'src/rtl').rglob('*'))
summary['source_sha256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}
(OUT/'consumer_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
lines=['# FP8 consumer: front / core / back','',
'Boundary: input available in external Flash → internal input DMA, complete EGRU and FC → two FC bytes committed to external Flash. Ignore all PC work after result emission. Batch 1, 1 KiB SRAM, same eight-neuron schedule as the [full-network benchmark](performance_fp8_1k.md).','',
'## Three separately characterized costs','',
'| Part | Result at 50 MHz | Meaning |','|---|---|---|',
'| Front: current UART command supply | See measured marginal overhead below (about 1.11 seconds) | Actual UART/READY versus ideal command availability; excludes unimplemented PC-to-input-Flash delivery |',
f"| Core | {min(r['compute_cycles'] for r in rows)/50000:.3f}–{max(r['compute_cycles'] for r in rows)/50000:.3f} ms in 20 RTL frames | Complete input DMA + EGRU state update + FC; ideal command availability |",
'| Back: result Flash commit | 6.0091 ms | Both output bytes verified; two program operations at 3 ms each, plus command/bus/polling cycles |','',
'Core-only testing injects commands at the existing instruction FIFO input and respects its capacity and downstream backpressure. All functional compute/memory RTL remains active. This is a controlled isolation experiment; the chip does not currently contain a local instruction stream that achieves it. In both modes all 256 c values, 256 y values and both FC values are compared with the FP8 reference. Flash result bytes are also compared. Twenty ideal-feed cases and three UART-fed complete-output cases passed.','',
'The output timing uses the 3 ms maximum tPP from the [Winbond W25Q128JV Revision J datasheet, p.65](https://www.mouser.com/datasheet/2/949/Winbond_Electronics_Corporation_09_06_2024_W25Q128-3501276.pdf). Current RTL programs one byte per transaction, hence two programs. This is a conservative simulated Flash condition, not a measured board latency. Erased output storage is assumed available; erase/recycling is outside this finite log test. No numerical-result UART transmitter exists in the current RTL, so UART output is not reported as implemented.','',
'## Additive comparison without double counting','',
'Front below is **effective added latency** = UART-fed total − ideal-fed total. It already accounts for overlap and includes the commands that initiate output writes. It is not UART wire time plus an independent core time. Adding wire duration and busy counters directly would double-count overlaps.','',
'| Bishop 0 step | Front extra (ms) | Core (ms) | Back (ms) | Sum / measured total (ms) |','|---|---:|---:|---:|---:|']
for r in combined:lines.append(f"| {r['step']} | {r['front_extra_ms']:.3f} | {r['core_ms']:.3f} | {r['back_ms']:.3f} | {r['total_ms']:.3f} |")
lines+=['','## Sustained input consumption','',
'At 20 ms arrivals, a frame occasionally taking more than 20 ms can be buffered. Sustained average service time must nevertheless stay below 20 ms, and queueing must fit the 100 ms latency allowance.','',
'An activity-count timing model matches all 12 calibration RTL cases and all eight independent held-out RTL cases exactly (zero cycle error):','',
'`core_cycles = base[dataset] + 27648 * active_input + 23616 * active_previous_y + 177 * active_new_y`','',
'Bases are 272712, 273630, 273630, 274740 for Bishop 0–3. Held-outs use one median-activity step and one seeded random step per dataset. The following averages apply that calibrated model to all 103,133 steps of the complete FP8 software trace; they are **projections**, not full-dataset RTL measurements.','',
'| Dataset | Projected core mean at 50 MHz (ms) | Average-rate minimum (MHz) | 20% time headroom (MHz) |','|---|---:|---:|---:|']
for d in datasets:lines.append(f"| bishop_{d['dataset']} | {d['core_mean_ms']:.3f} | {d['core_only_average_rate_mhz']:.2f} | {d['core_only_20percent_margin_mhz']:.2f} |")
lines+=['','The core alone is therefore not sustainable at 50 MHz under this schedule, even with ideal commands. Average-rate thresholds have zero slack; the margin column targets 16 ms rather than 20 ms. These are arithmetic clock equivalents, not achievable-clock claims. Burst activity and the 100 ms queueing limit can require considerably more headroom than the mean suggests.','',
'Projected FIFO queue recurrence: `finish[i] = max(arrival[i], finish[i-1]) + service[i]`, with arrivals every 20 ms, no inter-trial gaps, no dropped/coalesced inputs. Software states reset at trial offsets; extra RTL reset commands are omitted. Clock sweeps scale logic/read cycles only; the two 3 ms Flash program waits stay fixed.','',
'| Dataset | Core-only minimum clock for all projected latencies ≤100 ms (MHz) | Core + worst-tPP Flash (MHz) |','|---|---:|---:|']
for d in datasets:lines.append(f"| bishop_{d['dataset']} | {d['core_only_100ms_deadline_mhz']:.2f} | {d['core_flash_100ms_deadline_mhz']:.2f} |")
lines+=['','These queue thresholds are model-only lower estimates for the stated schedule and timing assumptions, excluding front-end and trial-reset overhead; they are not physical signoff. Finite selected-frame bit-exact tests do not prove loss-free indefinite operation. At 50 MHz, the average deficit already proves that an indefinitely buffered stream cannot be sustained by this schedule.','',
'## Reproduce and artifacts','',
'Prepare FP8 data and software reference traces as described in the full-network report, then run:','',
'```sh','make -f test/Makefile.consumer','```','',
'`reports/fp8_full/consumer_summary.json` stores measured costs, cycle model, queue projections and source hashes. `consumer_cases.json` and `consumer_holdout_cases.json` identify fixtures; each case retains command/Flash/expected data and result logs. Numerical validation uses the chip FP8/hard-activation reference, not original FP16 model accuracy. No P&R/timing closure was performed.']
(ROOT/'docs/performance_fp8_consumer.md').write_text('\n'.join(lines)+'\n')
print('20 core cases and 3 UART + output cases passed; additive front/core/back report generated')
