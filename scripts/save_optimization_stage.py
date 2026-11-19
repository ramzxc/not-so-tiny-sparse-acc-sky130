#!/usr/bin/env python3
"""Save immutable sources and available simulation evidence before synthesis."""
import argparse,json,shutil,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('stage');a=p.parse_args();out=ROOT/'reports/optimization_stages'/a.stage
out.mkdir(parents=True,exist_ok=False)
for name in ('src','test','scripts'):shutil.copytree(ROOT/name,out/name,ignore=shutil.ignore_patterns('__pycache__','sim_build','*.fst','*.vcd'))
rows=[]
for path in json.loads((ROOT/'reports/psram_stream/cases.json').read_text()):
 case=Path(path);rows.append(dict(case=case.name,meta=json.loads((case/'stream.json').read_text()),result=json.loads((case/'result.json').read_text()),profile=json.loads((case/'profile.json').read_text()) if (case/'profile.json').exists() else None))
(out/'measurements.json').write_text(json.dumps(rows,indent=2)+'\n')
(out/'rtl_hashes.json').write_text(json.dumps({str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (out/'src').rglob('*') if p.is_file()},indent=2)+'\n')
print(out)
