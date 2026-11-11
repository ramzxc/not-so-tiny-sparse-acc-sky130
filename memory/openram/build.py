"""Generate either independent 1RW macro; no top-level RTL integration."""
import argparse,os,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('words',type=int,choices=[64,128]);p.add_argument('--words-per-row',type=int,choices=[1,2,4,8],default=None);p.add_argument('--geometry-only',action='store_true');p.add_argument('--no-supply-routing',action='store_true');a=p.parse_args()
a.words_per_row=a.words_per_row or (2 if a.words==64 else 4)
r=Path(__file__).resolve().parent
openram=Path(os.environ.get('TT_OPENRAM_ROOT','/tmp/tt-openram-dev'))
python=os.environ.get('TT_OPENRAM_PYTHON','/tmp/tt-openram-venv/bin/python')
default_wpr=2 if a.words==64 else 4
label=f'64x{a.words}_custom_tapped' if a.words_per_row==default_wpr and not a.no_supply_routing else f'64x{a.words}_custom_wpr{a.words_per_row}'+('_nosupply' if a.no_supply_routing else '_supply')
out=r/'runs'/label
out.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env.update(OPENRAM_HOME=str(openram/'compiler'),OPENRAM_TECH=str(openram/'technology'),PDK_ROOT=os.environ.get('TT_PDK_ROOT','/tmp/tt-openram-pdk'),TT_SRAM_OUTPUT=str(out),TT_WORDS_PER_ROW=str(a.words_per_row),TT_ROUTE_SUPPLIES='0' if a.no_supply_routing else '1',PYTHONUNBUFFERED='1',OPENBLAS_NUM_THREADS='1')
env['PATH']='/tmp/tt-magic/bin:/tmp/tt-netgen/bin:'+env['PATH']
cmd=[python,str(openram/'sram_compiler.py')]
if a.geometry_only:cmd+=['-n']
cmd += [str(r/'configs'/f'sky130_1rw_64x{a.words}.py')]
with (out/'build.log').open('w') as f:subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
print(out)
