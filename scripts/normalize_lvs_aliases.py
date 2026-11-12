"""Canonicalize explicit ideal 0-ohm aliases; preserve all port names and physical devices.
No connection is inferred from the opposite comparison circuit.
"""
import json,re,sys,hashlib
from pathlib import Path
from decimal import Decimal,InvalidOperation
source,target=map(Path,sys.argv[1:3])
text=source.read_text()
logical=re.sub(r'\n\s*\+', ' ', text).splitlines()
output=[]; block=[]; reports=[]
def convert(lines):
    uf={}; zeros=[]
    def find(n):
        uf.setdefault(n,n)
        if uf[n]!=n:uf[n]=find(uf[n])
        return uf[n]
    for i,line in enumerate(lines):
        t=line.split()
        if len(t)!=4 or not t[0].lower().startswith('r'):continue
        try:iszero=Decimal(t[3])==0
        except InvalidOperation:continue
        if iszero:
            uf[find(t[1])]=find(t[2]);zeros.append(i)
    if not zeros:return lines
    groups={}
    for n in uf:groups.setdefault(find(n),[]).append(n)
    canonical={n:min(g) for g in groups.values() for n in g}
    rewritten=[]; device_count=0
    for i,line in enumerate(lines):
        if i in zeros:continue
        t=line.split()
        if t and not t[0].startswith(('.', '*')):
            # Only node names participating in explicit ideal short groups change.
            t=[t[0]]+[canonical.get(n,n) for n in t[1:]]
            line=' '.join(t);device_count+=1
        if t and t[0].lower()=='.ends':
            k=0
            for g in sorted(groups.values(),key=min):
                for n in sorted(g):
                    if n!=min(g):
                        name=f'R__lvs_alias_{k}'
                        assert not any(x.split() and x.split()[0]==name for x in lines)
                        rewritten.append(f'{name} {min(g)} {n} 0');k+=1
        rewritten.append(line)
    # Each rewrite is a spanning star of precisely the same zero-ohm component.
    reports.append({'subckt':lines[0].split()[1], 'components':list(groups.values()),
                    'original_zero_resistors':len(zeros),'physical_devices_preserved':device_count,
                    'port_header_preserved':rewritten[0]==lines[0]})
    return rewritten
for line in logical:
    if line.lower().startswith('.subckt '):
        assert not block
        block=[line]
    elif block:
        block.append(line)
        if line.lower().startswith('.ends'):
            output.extend(convert(block));block=[]
    else:output.append(line)
assert not block
target.write_text('\n'.join(output)+'\n')
target.with_suffix(target.suffix+'.json').write_text(json.dumps({'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'result_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'components':reports},indent=2)+'\n')
