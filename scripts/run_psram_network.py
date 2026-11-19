#!/usr/bin/env python3
import argparse,json,subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--binary',default='/tmp/acc-psram-network/Vtb_psram_network');p.add_argument('--limit',type=int);p.add_argument('--profile',action='store_true');p.add_argument('--jobs',type=int,default=3);args=p.parse_args()
def run(name):
    case=Path(name);m=json.loads((case/'stream.json').read_text())
    cmd=[args.binary,f'+FIXTURE={case}/psram.hex',f'+EXPECTED={case}/expected.hex',f'+REPORT={case}/result.json',f'+PROGRAM={m["program_base"]}',f'+WORDS={m["program_words"]}',f'+INPUT_BYTES={m["input_width"]}']
    if args.profile:cmd += [f'+PROFILE={case}/profile.json',f'+PHASES={case}/phases.hex']
    with (case/'simulation.log').open('w') as log:r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
    if r.returncode:raise RuntimeError((case/'simulation.log').read_text())
    print(case.name,json.loads((case/'result.json').read_text()),flush=True)
with ThreadPoolExecutor(max_workers=args.jobs) as pool:list(pool.map(run,json.loads((ROOT/'reports/psram_stream/cases.json').read_text())[:args.limit]))
