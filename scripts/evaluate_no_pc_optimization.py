#!/usr/bin/env python3
"""Paired full-network RTL timing and finite PSRAM queue projections.

Uses existing warm-state fixtures; whole-trace queue results are projections.
"""
import argparse,json,subprocess,hashlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/no_pc_optimization'
KEYS=['input','previous','output']

def simulate(item):
 version,binary,case=item;m=json.loads((case/'stream.json').read_text())
 dest=OUT/version/f'bishop_{m["dataset"]}_step_{m["step"]}';dest.mkdir(parents=True,exist_ok=True)
 cmd=[binary,f'+FIXTURE={case}/psram.hex',f'+EXPECTED={case}/expected.hex',f'+REPORT={dest}/result.json',f'+PROGRAM={m["program_base"]}',f'+WORDS={m["program_words"]}',f'+INPUT_BYTES={m["input_width"]}']
 with (dest/'simulation.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
 r=json.loads((dest/'result.json').read_text());assert r['mismatches']==0
 return dict(dataset=m['dataset'],step=m['step'],input_width=m['input_width'],result=r,case=str(case))

def project(service,capacity=16384):
 n=len(service);arrivals=np.arange(n)*20.
 finish=np.empty(n);last=0.
 for i,v in enumerate(service):last=max(arrivals[i],last)+float(v);finish[i]=last
 # Conservative: count a record for the entire service, including SRAM execution.
 # Actual PSRAM slot is released after input replay, before execution completes.
 queued=np.arange(n)+1-np.searchsorted(finish,arrivals,side='right')
 waiting=np.maximum(0,np.r_[0,finish[:-1]]-arrivals)
 overflow=np.flatnonzero(queued>capacity)
 first_wait=np.flatnonzero(waiting>0)
 recovery=np.flatnonzero((waiting==0)&(np.r_[0,waiting[:-1]]>0))
 last_recovery=int(recovery[-1]) if len(recovery) else None
 drain=max(0,float((finish[-1]-n*20)/1000))
 return dict(frames=n,capture_seconds=n*.02,mean_service_ms=float(np.mean(service)),
  peak_slots=int(queued.max()),peak_mib=float(queued.max()*256/2**20),
  overflow_first_seconds=None if not len(overflow) else float(arrivals[overflow[0]]/1000),
  last_response_seconds=float((finish[-1]-arrivals[-1])/1000),
  max_response_seconds=float(np.max(finish-arrivals)/1000),drain_after_capture_seconds=drain,
  outstanding_at_capture_end=int(n-np.searchsorted(finish,n*20,side='right')),
  backlog_recoveries=len(recovery),last_backlog_recovery_seconds=None if last_recovery is None else last_recovery*.02,
  first_backlog_seconds=None if not len(first_wait) else int(first_wait[0])*.02)

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--before',default='/tmp/acc-no-pc-baseline/Vtb_psram_network');p.add_argument('--after',default='/tmp/acc-no-pc-optimized/Vtb_psram_network');p.add_argument('--reuse',action='store_true');args=p.parse_args()
 OUT.mkdir(exist_ok=True)
 training={}
 for path in list((ROOT/'reports/stream_deadline').glob('bishop_*/stream.json'))+[Path(x)/'stream.json' for x in json.loads((ROOT/'reports/psram_stream/cases.json').read_text())]:
  m=json.loads(path.read_text());training[m['dataset'],m['step']]=path.parent
 train=list(training.values());hold=list((ROOT/'reports/realtime_buffers/holdouts').glob('bishop_*'))
 assert len(train)==20 and len(hold)==16
 activity=[np.genfromtxt(ROOT/f'reports/fp8_full/bishop_{d}/activity.csv',delimiter=',',names=True,dtype=int) for d in range(4)]
 all_results={};models={}
 for version,binary in [('before',args.before),('after',args.after)]:
  path=OUT/f'{version}_measured.json'
  if args.reuse:measured=json.loads(path.read_text())
  else:
   with ThreadPoolExecutor(max_workers=2) as pool:measured=list(pool.map(simulate,[(version,binary,c) for c in train+hold]))
   path.write_text(json.dumps(measured,indent=2)+'\n')
  def feature(r):
   d,t=r['dataset'],r['step'];return [int(d==i) for i in range(4)]+[int(activity[d][t][k]) for k in KEYS]
  x=np.array([feature(r) for r in measured[:20]],dtype=np.int64);y=np.array([r['result']['core_cycles'] for r in measured[:20]],dtype=np.int64)
  coeff=np.rint(np.linalg.lstsq(x,y,rcond=None)[0]).astype(np.int64)
  errors=[int(np.dot(feature(r),coeff))-r['result']['core_cycles'] for r in measured]
  assert not any(errors),errors
  overhead=[]
  for d in range(4):
   values={r['result']['cycles']-r['result']['core_cycles'] for r in measured if r['dataset']==d};assert len(values)==1;overhead.append(values.pop())
  models[version]=dict(coefficients=coeff.tolist(),uart_cycles=overhead,training=20,holdouts=16,max_error_cycles=0)
  rows=[]
  for d,a in enumerate(activity):
   core=(coeff[d]+sum(coeff[4+i]*a[k] for i,k in enumerate(KEYS)))/50000
   # Main sizing deliberately retains all legacy UART time, adds 0.3 ms/frame
   # for queue transport, and ignores input/compute overlap. This is a budget
   # assumption, not a calibrated concurrent-bus timing model or formal bound.
   budget=core+overhead[d]/50000+.3
   nominal=core+.15 # Separate illustrative overlapped estimate, not pass evidence.
   slow=budget*1.10
   repeats=np.resize(slow,180000)
   rows.append(dict(dataset=d,core_mean_ms=float(core.mean()),
    optimistic_core_only=project(core),overlapped_estimate=project(nominal),
    conservative_budget=project(budget),budget_10percent_slower=project(slow),
    hour_repeated_budget_10percent_slower=project(repeats)))
  all_results[version]=rows
  print(version,models[version],flush=True)
  for r in rows:print(version,r['dataset'],json.dumps(r['budget_10percent_slower']),flush=True)
 source_hash={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in (ROOT/'src/rtl').rglob('*') if f.is_file()}
 report=dict(models=models,datasets=all_results,queue_slots=16384,slot_bytes=256,clock_mhz=50,input_interval_ms=20,
  baseline_commit='5c158d4',binary_sha256={v:hashlib.sha256(Path(b).read_bytes()).hexdigest() for v,b in [('before',args.before),('after',args.after)]},
  limits='Per-frame RTL verified with software-reference warm states; queue projections are not live recurrent or full-trace RTL tests. Trial segments concatenated without unrecorded gaps. Conservative transport budgets and slowdown are assumptions, not guaranteed worst-case bounds. No 100ms deadline is imposed. Counts include current service conservatively. Program must be relocated below reserved 0x400000..0x7fffff queue.',source_sha256=source_hash)
 (OUT/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
