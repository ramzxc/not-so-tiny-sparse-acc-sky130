#!/usr/bin/env python3
"""Calibrate current aligned network timing, validate holdouts, project host queues.

This is not a live recurrent-stream RTL test or physical timing signoff.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path

import numpy as np
import evaluate_stream_deadline as bench

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/realtime_buffers'
KEYS=['input','previous','output']


def features(dataset, activity):
    return [int(dataset==i) for i in range(4)]+[int(activity[k]) for k in KEYS]


def queue(service_ms, arrivals_ms, frame_bytes, capacity=None):
    # Infinite reference queue; infer required bounded capacity from occupancy.
    # Slots include one input currently being transmitted/executed, conservatively.
    n=len(service_ms)
    finish=np.empty(n,dtype=float)
    prev=0.0
    for i in range(n):
        prev=max(prev,float(arrivals_ms[i]))+float(service_ms[i]);finish[i]=prev
    outstanding=np.arange(1,n+1)-np.searchsorted(finish,arrivals_ms,side='right')
    latency=finish-arrivals_ms
    maximum=int(outstanding.max())
    result=dict(inputs=n,capture_seconds=float((arrivals_ms[-1]+20)/1000),
                mean_service_ms=float(np.mean(service_ms)),max_service_ms=float(np.max(service_ms)),
                mean_latency_ms=float(latency.mean()),max_latency_ms=float(latency.max()),
                peak_outstanding_frames=maximum,peak_input_bytes=maximum*frame_bytes,
                max_waiting_frames=max(0,maximum-1),
                backlog_frames_at_capture_end=int(n-np.searchsorted(finish,arrivals_ms[-1]+20,side='right')),
                drain_after_capture_seconds=max(0.,float((finish[-1]-arrivals_ms[-1]-20)/1000)),
                latency_over_100ms=int(np.sum(latency>100)))
    if capacity is not None:
        slots=capacity//frame_bytes
        overflow=np.flatnonzero(outstanding>slots)
        result.update(capacity_bytes=capacity,capacity_frames=slots,
                      first_overflow_seconds=None if not len(overflow) else float(arrivals_ms[overflow[0]]/1000))
    return result


def check_queue():
    # Independent event accounting for a short mixed-load producer/consumer trace.
    arrivals=np.array([0.,20.,40.,60.,80.]);service=np.array([5.,50.,1.,60.,2.])
    starts=[];finishes=[];last=0.
    for arrival,duration in zip(arrivals,service):
        starts.append(max(arrival,last));last=starts[-1]+duration;finishes.append(last)
    counts=[sum(a<=t<f for a,f in zip(arrivals,finishes)) for t in arrivals]
    result=queue(service,arrivals,10,20)
    assert result['peak_outstanding_frames']==max(counts)
    assert result['max_latency_ms']==max(f-a for f,a in zip(finishes,arrivals))
    assert result['first_overflow_seconds']==arrivals[next(i for i,c in enumerate(counts) if c>2)]/1000
    assert queue(np.array([20.,20.]),np.array([0.,20.]),10,10)['first_overflow_seconds'] is None


def main():
    check_queue()
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',default='/tmp/acc-deadline-buffered/Vtb_psram_network')
    parser.add_argument('--reuse-holdouts',action='store_true')
    args=parser.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    activity=[np.genfromtxt(ROOT/f'reports/fp8_full/bishop_{d}/activity.csv',delimiter=',',names=True,dtype=int) for d in range(4)]
    training={}
    candidates=list((ROOT/'reports/stream_deadline').glob('bishop_*/stream.json'))
    candidates += [Path(p)/'stream.json' for p in json.loads((ROOT/'reports/psram_stream/cases.json').read_text())]
    for path in candidates:
        meta=json.loads(path.read_text());r=json.loads((path.parent/'result.json').read_text())
        assert meta['layout']['weights']==[960,983] and r['mismatches']==0
        training[meta['dataset'],meta['step']]=dict(dataset=meta['dataset'],step=meta['step'],result=r,meta=meta)
    assert len(training)==20
    x=np.array([features(d,activity[d][t]) for d,t in training],dtype=np.int64)
    y=np.array([r['result']['core_cycles'] for r in training.values()],dtype=np.int64)
    coeff=np.rint(np.linalg.lstsq(x,y,rcond=None)[0]).astype(np.int64)
    assert np.array_equal(x@coeff,y)
    overhead=[];widths=[]
    for d in range(4):
        values={r['result']['cycles']-r['result']['core_cycles'] for (ds,_),r in training.items() if ds==d}
        assert len(values)==1;overhead.append(values.pop())
        widths.append(next(r['meta']['input_width'] for (ds,_),r in training.items() if ds==d))
    # Choose holdouts independently of fitting: low/median/p90 activity and seeded random.
    bench.OUT=OUT/'holdouts'
    bench.OUT.mkdir(exist_ok=True)
    rng=np.random.default_rng(20261120)
    cases=[]
    for d in range(4):
        order=np.argsort(activity[d]['input']+activity[d]['previous'],kind='stable')
        selected=[]
        for q in (0.,.5,.9):
            index=int(q*(len(order)-1))
            while (d,int(order[index])) in training or int(order[index]) in selected:index+=1
            selected.append(int(order[index]))
        while len(selected)<4:
            t=int(rng.integers(len(order)))
            if (d,t) not in training and t not in selected:selected.append(t)
        for t in selected:
            case=bench.OUT/f'bishop_{d}_step_{t}'
            if not args.reuse_holdouts:case=bench.prepare(d,t)
            cases.append(case)
    if not args.reuse_holdouts:
        with ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(lambda p:bench.run(p,args.binary),cases))
    held=[]
    for case in cases:
        meta=json.loads((case/'stream.json').read_text());r=json.loads((case/'result.json').read_text())
        d,t=meta['dataset'],meta['step']
        predicted=int(np.dot(features(d,activity[d][t]),coeff))
        assert r['mismatches']==0
        assert predicted==r['core_cycles'],(d,t,predicted,r)
        assert predicted+overhead[d]==r['cycles']
        held.append(dict(dataset=d,step=t,predicted_cycles=predicted,result=r))
    datasets=[]
    for d in range(4):
        a=activity[d];n=len(a)
        core=coeff[d]+sum(coeff[i+4]*a[k] for i,k in enumerate(KEYS))
        service=(core+overhead[d])/50000
        offsets=np.fromfile(ROOT/f'reports/fp8_full/bishop_{d}/offsets.bin',dtype='<u8')
        starts=offsets[offsets<n].astype(int);assert starts[0]==0
        # Account for 8-byte timestamp/sequence metadata per FP8 input record.
        frame_bytes=widths[d]+8
        arrivals=np.arange(n)*20.
        scenarios={}
        for label,count in [('first_10_seconds',min(n,500)),('first_60_seconds',min(n,3000)),('full_continuous',n)]:
            scenarios[label]=queue(service[:count],arrivals[:count],frame_bytes)
        scenarios['full_10percent_slower']=queue(service*1.10,arrivals,frame_bytes)
        # Optimistic diagnostic: remove all UART and warm-state setup entirely.
        scenarios['core_without_initialization']=queue(np.maximum(0,core/50000-.0918),arrivals,frame_bytes)
        for gap_ms in [1000,5000]:
            trial_index=np.searchsorted(starts,np.arange(n),side='right')-1
            delayed=arrivals+gap_ms*trial_index
            scenarios[f'trial_gap_{gap_ms}ms']=queue(service,delayed,frame_bytes)
        # Repeat the entire measured activity trace to test long-run accumulation.
        repeats=3
        scenarios['three_repeated_sessions']=queue(np.tile(service,repeats),np.arange(n*repeats)*20.,frame_bytes)
        hour_service=np.resize(service,180000)
        hour_arrivals=np.arange(180000)*20.
        scenarios['one_hour_repeated_trace']=queue(hour_service,hour_arrivals,frame_bytes)
        scenarios['one_hour_10percent_slower']=queue(hour_service*1.10,hour_arrivals,frame_bytes,16*1024*1024)
        hour_buffers={str(capacity):queue(hour_service,hour_arrivals,frame_bytes,capacity)
                      for capacity in [64*1024,256*1024,1024*1024,8*1024*1024,16*1024*1024]}
        buffers={str(capacity):queue(service,arrivals,frame_bytes,capacity)
                 for capacity in [64*1024,256*1024,1024*1024,8*1024*1024]}
        # Largest window-average service in any contiguous 10 and 60 seconds.
        prefix=np.r_[0.,np.cumsum(service)]
        windows={}
        for length in [500,3000]:
            means=(prefix[length:]-prefix[:-length])/length
            start=int(np.argmax(means));windows[str(length*20//1000)]=dict(start_step=start,mean_service_ms=float(means[start]))
        ideal_clear=[]
        ends=list(starts[1:])+[n]
        for start,end in zip(starts,ends):
            q=queue(service[start:end],np.arange(end-start)*20.,frame_bytes)
            ideal_clear.append(q['drain_after_capture_seconds'])
        datasets.append(dict(dataset=d,steps=n,trial_count=len(starts),input_width=widths[d],record_bytes=frame_bytes,
            core_mean_ms=float(core.mean()/50000),total_mean_ms=float(service.mean()),
            projected_inputs_per_second=float(1000/service.mean()),
            mean_backlog_growth_frames_per_second=float(50-1000/service.mean()),
            mean_safe_input_interval_ms=float(service.mean()),
            input_interval_20percent_idle_ms=float(service.mean()/0.8),
            mean_rate_clock_equivalent_mhz=float(service.mean()/20*50),
            required_gap_to_clear_each_trial_seconds=dict(max=max(ideal_clear),mean=float(np.mean(ideal_clear))),
            worst_window_means=windows,scenarios=scenarios,buffers=buffers,one_hour_buffers=hour_buffers))
    files=list((ROOT/'src/rtl').rglob('*'))+[Path(__file__),ROOT/'scripts/prepare_fp8_network.py',ROOT/'scripts/evaluate_stream_deadline.py']
    report=dict(clock_mhz=50,input_interval_ms=20,model=dict(base_by_dataset=coeff[:4].tolist(),
                active_input_cycles=int(coeff[4]),active_previous_y_cycles=int(coeff[5]),active_output_cycles=int(coeff[6]),
                uart_overhead_cycles_by_dataset=overhead,training_cases=20,holdout_cases=len(held),max_error_cycles=0),
                holdouts=held,datasets=datasets,
                assumptions='FIFO in PC RAM; one record = FP8 input bytes + 8 metadata bytes, compact storage (not Python object overhead). Records include one in service. All results drain to PSRAM; downstream processing excluded. No input dropping. Real trial gaps unknown; 1s/5s gaps are synthetic. State trajectories are existing FP8 software references; per-frame RTL runs warm-start from those references. Current fixture warm-state reload included in timing, live recurrent state carry/reset driver not validated. Continuous trace joins reset trials with no timing gap. 50MHz and ideal modeled PSRAM, not board timing signoff. Full-trace queue results are calibrated model projections, not full-trace RTL.',
                source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()})
    (OUT/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print('MODEL',report['model'])
    for d in datasets:
        print('DATASET',d['dataset'],'core/total',d['core_mean_ms'],d['total_mean_ms'],'queue',d['scenarios']['full_continuous'])


if __name__=='__main__':main()
