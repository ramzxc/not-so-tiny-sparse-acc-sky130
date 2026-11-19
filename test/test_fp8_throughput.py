"""Component cycles for the FP8/1 KiB build; not an EGRU performance estimate."""
import json
import os
from pathlib import Path
import cocotb
from test_fp8_serial import host, config

@cocotb.test()
async def components(d):
    h=host(d);await h.reset();rows=[]
    def counters():
        return [int(d.perf_total_cycles.value),int(d.perf_dma_cycles.value),int(d.perf_micro_cycles.value)]
    for count in (1,8,64,128,255):
        before=counters();await h.dma_copy(0x800,512,count);after=counters()
        assert not int(d.uo_out.value)&2
        rows.append(dict(kind='dma',vectors=count,bytes=count*2,
                         host_cycles=after[0]-before[0],dma_cycles=after[1]-before[1]))
    for batch,source,columns in [(1,0x200,5),(3,0x400,3),(4,0x600,3)]:
        await h.dma_copy(source,0,((columns+1)//2)*batch)
        await h.dma_copy(0x1000,768,2*batch)
        before=counters();await config(h,0,0x300 if batch==1 else 0x500,768,2,columns,batch)
        await h.instruction(0xb403);await h.fence();after=counters()
        assert not int(d.uo_out.value)&2
        rows.append(dict(kind='micro_auto_dma',batch=batch,columns=columns,groups=2,
                         host_cycles=after[0]-before[0],dma_cycles=after[1]-before[1],
                         micro_cycles=after[2]-before[2]))
    output=Path(os.environ['PERF_OUTPUT']);output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(dict(format='FP8 E4M3FN',sram_bytes=1024,vector_bytes=2,
                                     uart_divider=h.period,rows=rows),indent=2)+'\n')
