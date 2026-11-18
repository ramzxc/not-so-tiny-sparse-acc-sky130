#!/usr/bin/env python3
"""Convert OpenRAM W/L to Magic's micron convention and select active PDK models."""
import os
from pathlib import Path
import re
from sky130_lvs_models import narrow_nfet_rule, select_nfet_models
root = Path(__file__).resolve().parents[1]
folder = root / 'memory/openram/generated/tt_sram_1rw_64x64_sky130'
tech = Path(os.environ['PDK_ROOT']) / os.environ.get('PDK','sky130A') / 'libs.tech/magic/sky130A.tech'
text = (folder / 'tt_sram_1rw_64x64_sky130.lvs.sp').read_text()
text = re.sub(r'\b([wl])=([0-9.]+)u\b', r'\1=\2', text, flags=re.I)
text, count = select_nfet_models(text, narrow_nfet_rule(tech.read_text()))
text = '\n'.join(line.rstrip() for line in text.splitlines()) + '\n'
(folder / 'sram.lvs_micron.spice').write_text('* Generated from OpenRAM LVS source for the active PDK.\n' + text)
print(f'SRAM LVS source prepared; narrow NFETs selected: {count}')
