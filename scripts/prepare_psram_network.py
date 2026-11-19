#!/usr/bin/env python3
"""Board-loaded PSRAM data/programs; inputs arrive only over UART at runtime."""
import json
from pathlib import Path
import numpy as np
from prepare_fp8_network import build
from compact_sram import compact_sram
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/psram_stream'
OUT.mkdir(parents=True,exist_ok=True)
cases=[]
for ds in range(4):
    stats=np.genfromtxt(ROOT/f'reports/fp8_full/bishop_{ds}/activity.csv',delimiter=',',names=True,dtype=int)
    for t in sorted({0,100,int(np.argmax(stats['input']+stats['previous']))}):
        case=Path(build(ds,t,consumer=True,stream=True))
        tagged=[int(w,16) for w in (case/'commands.hex').read_text().split() if int(w,16)>>16!=65535]
        uncompressed_words=len(tagged)
        tagged=compact_sram(tagged)
        words=[w&65535 for w in tagged]
        (case/'phases.hex').write_text(''.join(f'{w>>16:x}\n' for w in tagged))
        base=0x300000
        with (case/'psram.hex').open('w') as f:
            f.write((case/'flash.hex').read_text());f.write(f'@{base:x}\n')
            for w in words:f.write(f'{w&255:02x}\n{w>>8:02x}\n')
        meta=json.loads((case/'metadata.json').read_text());meta.update(program_base=base,program_words=len(words),uncompressed_program_words=uncompressed_words)
        (case/'stream.json').write_text(json.dumps(meta,indent=2)+'\n');cases.append(str(case))
(OUT/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')
