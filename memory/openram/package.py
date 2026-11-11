"""Package selected target macros with completed, passing physical checks."""
from pathlib import Path
import shutil,json,re,hashlib,argparse
p=argparse.ArgumentParser()
p.add_argument("--words", type=int, choices=[64,128], nargs="+", default=[64,128])
args=p.parse_args()
root=Path(__file__).resolve().parent
validated=[]
for words in args.words:
 wpr=2 if words==64 else 4
 src=root/'runs'/f'64x{words}_custom_tapped';name=f'tt_sram_1rw_64x{words}_sky130'
 checks=json.loads((src/'verification.json').read_text())
 assert checks.get('drc_errors')==0 and checks.get('lvs_errors')==0 and checks.get('final_verification'),(name,checks)
 assert 'Total DRC errors found: 0' in (src/'verification'/f'{name}.drc.out').read_text()
 report=(src/'verification'/f'{name}.lvs.report').read_text()
 assert 'Final result: Circuits match uniquely.' in report
 assert 'property errors' not in report.lower()
 for ext in ['.gds','.lvs.sp']:
  assert checks['checked_sha256'][ext]==hashlib.sha256((src/(name+ext)).read_bytes()).hexdigest()
 assert 'PASS:' in (src/'behavioral_test.log').read_text()
 w,h=map(float,re.search(r'SIZE\s+([\d.]+)\s+BY\s+([\d.]+)',(src/(name+'.lef')).read_text()).groups())
 assert w<=1378.16 and h<=225.76,(name,w,h)
 validated.append((words,wpr,src,name,checks,w,h))
results=[]
for words,wpr,src,name,checks,w,h in validated:
 dst=root/'generated'/name;dst.mkdir(parents=True,exist_ok=True)
 for ext in ['.gds','.lef','.sp','.lvs.sp','.v','_TT_1p8V_25C.lib']:
  shutil.copy2(src/(name+ext),dst/(name+ext))
 shutil.copy2(root/'configs'/f'sky130_1rw_64x{words}.py',dst/'config.py')
 for f in ['behavioral_test.log','verification.json']:
  shutil.copy2(src/f,dst/f)
 for suffix in ['.drc.out','.drc.err','.lvs.report','.lvs.out','.drc.tcl']:
  shutil.copy2(src/'verification'/(name+suffix),dst/(name+suffix))
 for f in ['setup.tcl','.magicrc','run_ext.sh','run_drc.sh','run_lvs.sh']:
  shutil.copy2(src/'verification'/f,dst/f)
 record={'name':name,'usable_bytes':words*8,'word_bits':64,'words':words,'words_per_row':wpr,'bitcell':'sky130_custom_cell','physical_data_port_bits':65,'spare_column':'unused; spare_wen0 tied low','ports':'1RW','width_um':w,'height_um':h,'area_um2':w*h,'outline_fits_8x2':True,'outline_vertical_margin_each_um':(225.76-h)/2,'physical_checks':checks,'release_status':'macro-level DRC/LVS PASS; top-level P&R and timing signoff not performed','liberty':'analytical TT estimate, not SPICE timing characterization','top_level_pnr':'not performed'}
 (dst/'status.json').write_text(json.dumps(record,indent=2)+'\n')
 sums={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(dst.iterdir()) if p.is_file() and (p.suffix in {'.gds','.lef','.sp','.v','.lib','.json'} or p.name=='config.py')}
 (dst/'SHA256SUMS').write_text(''.join(f'{v}  {k}\n' for k,v in sums.items()))
 results.append(record)
old=json.loads((root/'summary.json').read_text()) if (root/'summary.json').exists() else []
results += [entry for entry in old if entry['words'] not in args.words]
results.sort(key=lambda entry: entry['words'], reverse=True)
(root/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
