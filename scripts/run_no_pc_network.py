#!/usr/bin/env python3
"""Fixed-rate UART into PSRAM ring during complete network execution."""
import argparse,json,subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',default='/tmp/acc-no-pc-network/Vtb_no_pc_network');args=p.parse_args()
 out=ROOT/'reports/no_pc_buffer/network';out.mkdir(parents=True,exist_ok=True)
 def run(name):
  case=ROOT/'reports/fp8_full'/name;m=json.loads((case/'stream.json').read_text())
  dest=out/name;dest.mkdir(exist_ok=True)
  cmd=[args.binary,f'+FIXTURE={case}/psram.hex',f'+EXPECTED={case}/expected.hex',f'+REPORT={dest}/result.json',f'+PROGRAM={m["program_base"]}',f'+WORDS={m["program_words"]}',f'+INPUT_BYTES={m["input_width"]}']
  with (dest/'simulation.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
  r=json.loads((dest/'result.json').read_text());r['case']=name
  r['response_ms']=[v/50000-i*20 for i,v in enumerate(r['finish_cycles'])]
  r['deadline_misses_100ms']=sum(v>100 for v in r['response_ms'])
  r['completion_interval_ms']=[(b-a)/50000 for a,b in zip(r['finish_cycles'],r['finish_cycles'][1:])]
  print(json.dumps(r),flush=True);return r
 with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(run,['psram_bishop_2_step_100','psram_bishop_2_step_24067']))
 (out/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()
