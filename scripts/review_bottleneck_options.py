#!/usr/bin/env python3
"""Review candidate costs from measured counters; no RTL edits or synthesis."""
import json,hashlib
from pathlib import Path
from collections import Counter
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/bottleneck'
profile=json.loads((OUT/'profile.json').read_text());rows=[]

def row_chunks(dst,n):
    chunks=[]
    while n:
        size=min(n,4-(dst//2)%4)
        chunks.append((dst,size));dst+=size*2;n-=size
    return chunks

for r in profile['cases']:
    case=ROOT/'reports/fp8_full'/r['case'];p=r['profile']
    words=[int(x,16)&65535 for x in (case/'commands.hex').read_text().split() if int(x,16)>>16!=65535]
    shapes=Counter();addr=0;known=3;src=dst=None
    for w in words:
        op=w>>13
        if op==1:
            if w&0x1000:addr=(addr&4095)|((w&4095)<<12);known|=2
            else:addr=(addr&0xfff000)|(w&4095);known|=1
        elif op==5 and (w>>10)&7==5:known=0
        elif op==6:
            sub=(w>>10)&7
            if sub in (0,1):
                assert known==3
                if sub==0:src=addr
                else:dst=addr
            elif sub==2:
                assert src is not None and dst is not None
                if w&255:shapes[dst,w&255]+=1
    # On this batch-1 generator each active MICRO group has one 6-cycle SRAM
    # accumulate. Derive per-phase column counts from those measured operations.
    for phase,groups in [(2,8),(3,12),(5,4),(7,1)]:
        cycles=p['phases'][phase][2]
        assert cycles%(6*groups)==0
        shapes[956,groups]+=cycles//(6*groups)
    assert sum(shapes.values())==p['dma_runs']
    n=sum(count*runs for (dst,count),runs in shapes.items())
    assert n==p['requests'][0]-1  # exactly one non-DMA transaction: result write
    flat_chunks=sum(((count+3)//4)*runs for (dst,count),runs in shapes.items())
    bounded_chunks=partial_chunks=0
    for (dst,count),runs in shapes.items():
        chunks=row_chunks(dst,count);bounded_chunks+=len(chunks)*runs
        partial_chunks+=sum(size!=4 for _,size in chunks)*runs
    high_word_cycles=p['micro_states'][9]+p['micro_states'][16]
    groups=p['sram_accumulates']
    assert groups==p['micro_states'][9]==p['micro_states'][16]
    # Count exact stored-program SRAM setup patterns; this is a hypothetical
    # compact opcode, not a binary rewrite or a measured timing improvement.
    fused_ops=removed_words=0;i=0
    while i<len(words):
        w=words[i]
        if w in (0x8000,0x8400,0x9000):
            j=i+1
            while j<len(words) and words[j]>>13==1:j+=1
            if j<len(words) and words[j]==(0x5400 if w==0x9000 else 0x4400):
                fused_ops+=1;removed_words+=j-i;i=j+1;continue
        i+=1
    new_words=len(words)-removed_words
    fetch_cycles_saved=27*((len(words)+3)//4-(new_words+3)//4)+8*removed_words
    hist=Counter(w>>13 for w in words)
    rows.append(dict(case=r['case'],program_cycles=p['program_cycles'],dma_vectors=n,
        dma_shapes=[dict(destination=k[0],vectors=k[1],runs=v) for k,v in sorted(shapes.items())],
        flat_8byte_transactions=flat_chunks,row_bounded_transactions=bounded_chunks,
        row_partial_reads=partial_chunks,row_full_writes=bounded_chunks,
        flat_framing_cycles_saved=27*(n-flat_chunks),row_framing_cycles_saved=27*(n-bounded_chunks),
        skip_redundant_high_cycles=high_word_cycles,
        fuse_weight_and_acc_setup_cycles=6*groups,
        host_words=len(words),hypothetical_fused_ops=fused_ops,
        hypothetical_words_removed=removed_words,hypothetical_host_words=new_words,
        hypothetical_fetch_service_cycles_saved=fetch_cycles_saved,
        host_opcode_histogram=dict(sorted(hist.items()))))
(OUT/'options.json').write_text(json.dumps(rows,indent=2)+'\n')
for r in (min(rows,key=lambda r:r['program_cycles']),max(rows,key=lambda r:r['program_cycles'])):
    print(r['case'],json.dumps({k:v for k,v in r.items() if k not in ('case','dma_shapes','host_opcode_histogram')}))
# Check review has not changed the measured functional RTL.
for name,h in profile['rtl_sha256'].items():assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==h
