"""Measure auto-DMA tiles on external Flash mask fixtures; fit is performed separately."""
import json
import os
from pathlib import Path
import cocotb
from test_serial import Host

@cocotb.test()
async def measure_patterns(d):
    h=Host(d);h.period=int(os.environ.get('PERF_UART_CLKS_PER_BIT','87'));await h.reset()
    cases=json.loads(Path(os.environ.get('PERF_CASES','/tmp/acc-bishop-eval/cases.json')).read_text())
    rows=[]
    for case in cases:
        b,c,g=[case[k] for k in ('batch','columns','groups')]
        await h.dma_copy(case['source'],0,case['input_bytes']//4)
        # The zero fixture is 256 bytes; every selected test output fits it.
        await h.dma_copy(0xb00,case['acc'],b*g)
        await h.address(case['buffer']);await h.instruction(0xbc00)
        await h.address(case['acc']);await h.instruction(0xa800)
        await h.address(0);await h.instruction(0xbc01)
        await h.instruction(0xac00|g);await h.instruction(0xb800|b)
        # Retained configuration: restore consumed input/weight/count only.
        before=[int(d.perf_total_cycles.value),int(d.perf_micro_cycles.value),int(d.perf_dma_cycles.value)]
        await h.address(0);await h.instruction(0xa001)
        await h.address(0x1000);await h.instruction(0xa400)
        await h.instruction(0xb000|c)
        reads=int(d.flash_read_ops.value)
        await h.instruction(0xb403);await h.sync()
        after=[int(d.perf_total_cycles.value),int(d.perf_micro_cycles.value),int(d.perf_dma_cycles.value)]
        assert not int(d.uo_out.value)&2
        assert int(d.flash_read_ops.value)-reads==case['union_columns']
        row=dict(case,host_cycles=after[0]-before[0],micro_cycles=after[1]-before[1],
                 dma_cycles=after[2]-before[2],uart_words=11)
        rows.append(row);d._log.info('%s micro=%d host=%d',case['name'],row['micro_cycles'],row['host_cycles'])
    out=Path(os.environ.get('PERF_OUTPUT','/tmp/acc-bishop-eval/measurements.json'))
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps({'uart_divider':h.period,'rows':rows},indent=2)+'\n')
