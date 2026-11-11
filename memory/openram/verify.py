"""DRC/extraction and LVS of an already generated supply-routed macro."""
import os,sys,json,hashlib
from pathlib import Path
import openram
r=Path(__file__).resolve().parent
out=Path(sys.argv[1]).resolve();words=int(sys.argv[2]);name=f'tt_sram_1rw_64x{words}_sky130'
os.environ['TT_SRAM_OUTPUT']=str(out)
config=Path(sys.argv[3]).resolve() if len(sys.argv)>3 else r/'configs'/f'sky130_1rw_64x{words}.py'
openram.init_openram(str(config),is_unit_test=False)
from openram import OPTS,verify
name=OPTS.output_name
work=out/'verification';work.mkdir(exist_ok=True)
OPTS.openram_temp=str(work)+'/'
OPTS.check_lvsdrc=True
OPTS.drc_exe=('magic',os.environ.get('TT_MAGIC','/tmp/tt-magic/bin/magic'));OPTS.lvs_exe=('netgen',os.environ.get('TT_NETGEN','/tmp/tt-netgen/bin/netgen'))
drc=verify.run_drc(name,str(out/(name+'.gds')),sp_name=str(out/(name+'.lvs.sp')),extract=True,final_verification=True)
(out/'verification.json').write_text(json.dumps({'drc_errors':drc,'lvs_status':'running'},indent=2)+'\n')
lvs=verify.run_lvs(name,str(out/(name+'.gds')),str(out/(name+'.lvs.sp')),final_verification=True)
report=(work/(name+'.lvs.report')).read_text()
property_errors='property errors' in report.lower()
if property_errors: lvs=max(1,lvs)
if 'Final result: Circuits match uniquely.' not in report: lvs=max(1,lvs)
result={'drc_errors':drc,'lvs_errors':lvs,'lvs_property_errors':property_errors,'final_verification':True,
        'checked_sha256':{ext:hashlib.sha256((out/(name+ext)).read_bytes()).hexdigest() for ext in ['.gds','.lvs.sp']}}
(out/'verification.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
sys.exit(bool(drc or lvs))
