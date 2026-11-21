from pathlib import Path
import re
root=Path('/docker/projects/tapeout/not-so-tiny-sparse-acc-sky130');pdk=Path('/tmp/tt-ci-pdk/sky130A')
s=(pdk/'libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib').read_text()
def blocks(text,kind):
 for m in re.finditer(r'\b'+kind+r'\s*\(\s*"?([\w]+)"?\s*\)\s*\{',text):
  pos=m.end();depth=1;i=pos
  while depth:
   if text[i]=='{':depth+=1
   elif text[i]=='}':depth-=1
   i+=1
  yield m[1],text[pos:i-1]
models=[]
for name,body in blocks(s,'cell'):
 if re.search(r'\b(ff|latch)\s*\(',body):continue
 pins=[];decls=[];assigns=[]
 for pin,b in blocks(body,'pin'):
  direction=re.search(r'direction\s*:\s*"?(\w+)',b)
  if not direction or direction[1] not in ('input','output','inout'):continue
  pins.append(pin);decls.append(f'{direction[1]} {pin};')
  f=re.search(r'function\s*:\s*"([^"]+)"',b)
  if f:assigns.append(f'assign {pin} = {f[1]};')
 if not assigns:continue
 for pg in ('VPWR','VGND','VPB','VNB'):
  if pg not in pins:pins.append(pg);decls.append(f'input {pg};')
 models.append(f'module {name}('+','.join(pins)+');\n'+'\n'.join(decls+assigns)+'\nendmodule')
Path('/tmp/acc-combo-models.v').write_text('\n'.join(models))
cmds=[f'read_verilog -lib -D USE_POWER_PINS -D FUNCTIONAL -D UNIT_DELAY= {pdk}/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v',f'read_verilog -lib -D USE_POWER_PINS {root}/memory/openram/generated/tt_sram_1rw_64x128_buffered_sky130/blackbox.v','read_verilog -overwrite /tmp/acc-combo-models.v',f'read_verilog {root}/macro/acc_hard_macro/acc_hard_macro.v','hierarchy -check -top acc_hard_macro','flatten','proc','opt_clean','select -module acc_hard_macro','sat -verify -ignore_unknown_cells -set reset_sync[1] 0 -prove command.sequencer.n886 0','sat -verify -ignore_unknown_cells -set reset_sync[1] 0 -prove dma.n165 0']
Path('/tmp/acc-reset-proof.ys').write_text('\n'.join(cmds)+'\n')
