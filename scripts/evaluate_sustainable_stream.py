#!/usr/bin/env python3
"""Measure a compute candidate and project periodic PSRAM queue stability."""
import argparse,json,hashlib
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import evaluate_no_pc_optimization as bench
ROOT=Path(__file__).resolve().parents[1]

def periodic(service):
 n=len(service);arrivals=np.arange(3*n)*20.;s=np.tile(service,3)
 finish=np.empty(3*n);last=0.
 for i,v in enumerate(s):last=max(last,arrivals[i])+float(v);finish[i]=last
 occupancy=np.arange(3*n)+1-np.searchsorted(finish,arrivals,side='right')
 return dict(mean_service_ms=float(np.mean(service)),mean_rate_stable=bool(np.mean(service)<20),
  peak_slots_by_repeat=[int(occupancy[i*n:(i+1)*n].max()) for i in range(3)],
  unfinished_work_ms_at_period_end=[max(0.,float(finish[(i+1)*n-1]-(i+1)*n*20)) for i in range(3)],
  period_seconds=n*.02)

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',required=True);p.add_argument('--out',type=Path,default=ROOT/'reports/sustainable_stream/stage1');p.add_argument('--reuse',action='store_true');a=p.parse_args()
 out=a.out.resolve();out.mkdir(parents=True,exist_ok=True);bench.OUT=out
 source_hashes={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in (ROOT/'src/rtl').rglob('*') if f.is_file()}
 baseline=json.loads((ROOT/'reports/no_pc_optimization/after_measured.json').read_text())
 assert len(baseline)==36
 if a.reuse:measured=json.loads((out/'measured.json').read_text())
 else:
  with ThreadPoolExecutor(max_workers=2) as pool:measured=list(pool.map(bench.simulate,[('candidate',a.binary,Path(r['case'])) for r in baseline]))
  (out/'measured.json').write_text(json.dumps(measured,indent=2)+'\n')
 activity=[np.genfromtxt(ROOT/f'reports/fp8_full/bishop_{d}/activity.csv',delimiter=',',names=True,dtype=int) for d in range(4)]
 def feature(r):
  d,t=r['dataset'],r['step'];return [int(d==i) for i in range(4)]+[int(activity[d][t][k]) for k in bench.KEYS]
 x=np.array([feature(r) for r in measured[:20]],dtype=np.int64);y=np.array([r['result']['core_cycles'] for r in measured[:20]])
 coeff=np.rint(np.linalg.lstsq(x,y,rcond=None)[0]).astype(np.int64)
 errors=[int(np.dot(feature(r),coeff))-r['result']['core_cycles'] for r in measured]
 assert not any(errors),errors
 base_coeff=np.array(json.loads((ROOT/'reports/no_pc_optimization/summary.json').read_text())['models']['after']['coefficients'])
 datasets=[]
 for d,act in enumerate(activity):
  core=(coeff[d]+sum(coeff[4+i]*act[k] for i,k in enumerate(bench.KEYS)))/50000
  before=(base_coeff[d]+sum(base_coeff[4+i]*act[k] for i,k in enumerate(bench.KEYS)))/50000
  row=dict(dataset=d,before_core_mean_ms=float(before.mean()),after_core_mean_ms=float(core.mean()),
   reduction_percent=float((1-core.mean()/before.mean())*100),
   core_only=periodic(core),overlap_estimate=periodic(core+.15),
   queue_budget=periodic(core+.30),
   sensitivity_10percent=periodic(core*1.10+.30))
  datasets.append(row);print(json.dumps(row),flush=True)
 report=dict(baseline_commit='0350439',coefficients=coeff.tolist(),training=20,holdouts=16,max_model_error_cycles=0,datasets=datasets,
  assumptions='20ms arrivals, no PC queue, 16384 PSRAM slots. Periodic repeats of recorded activity. Core-only is optimistic; +0.15ms and 10% slower +0.30ms are explicit queue/interference sensitivity assumptions, not concurrent-bus calibration. Live recurrent state carry not validated. Stable refers only to mean service in these repeated traces; no deadline or universal workload guarantee.',
  binary_sha256=hashlib.sha256(Path(a.binary).read_bytes()).hexdigest(),
  source_sha256=source_hashes)
 (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
