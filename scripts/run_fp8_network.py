#!/usr/bin/env python3
"""Run selected complete-network RTL cases; requires the native bench binary."""
import argparse,json,subprocess,time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/fp8_full'
p=argparse.ArgumentParser();p.add_argument('--cases',default='cases.json');p.add_argument('--report-name',default='result');p.add_argument('--binary',default='/tmp/acc-fp8-full-native/Vtb_fp8_network');p.add_argument('--limit',type=int);p.add_argument('--jobs',type=int,default=1);p.add_argument('--skip-passed',action='store_true');args=p.parse_args()
def run(path):
    case=Path(path);meta=json.loads((case/'metadata.json').read_text());start=time.monotonic()
    if args.skip_passed and (case/f'{args.report_name}.json').exists() and json.loads((case/f'{args.report_name}.json').read_text())['mismatches']==0:return
    with (case/f'{args.report_name}.log').open('w') as log:
        result=subprocess.run([args.binary,f'+FLASH={case}/flash.hex',f'+COMMANDS={case}/commands.hex',f'+EXPECTED={case}/expected.hex',f'+REPORT={case}/{args.report_name}.json',f'+WORDS={meta["words"]}'],stdout=log,stderr=subprocess.STDOUT)
    print(case.name,'exit',result.returncode,'seconds',round(time.monotonic()-start,2),flush=True)
    if result.returncode:raise RuntimeError((case/f'{args.report_name}.log').read_text())
with ThreadPoolExecutor(max_workers=args.jobs) as pool:list(pool.map(run,json.loads((OUT/args.cases).read_text())[:args.limit]))
