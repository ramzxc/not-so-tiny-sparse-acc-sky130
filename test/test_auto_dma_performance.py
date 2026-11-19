"""Cycle measurements for generic auto-DMA tiles, including real UART setup."""
import json
import os
from pathlib import Path
import cocotb
from test_serial import Host

@cocotb.test()
async def measure_auto_dma(d):
    h=Host(d);h.period=int(os.environ.get('PERF_UART_CLKS_PER_BIT','87'))
    await h.reset()
    rows=[]
    for batches,columns,groups in [(1,1,32),(1,16,32),(1,64,32),(1,16,16),(4,16,16)]:
        await h.dma_copy(0xa00,0,32)
        acc=384 if groups==32 else 256
        await h.dma_copy(0xb00,acc,groups*batches)
        before=[int(d.perf_total_cycles.value),int(d.perf_dma_cycles.value),int(d.perf_micro_cycles.value)]
        await h.address(0);await h.instruction(0xa001)
        await h.address(0x1000);await h.instruction(0xa400)
        await h.address(128);await h.instruction(0xbc00)
        await h.address(acc);await h.instruction(0xa800)
        await h.address(0);await h.instruction(0xbc01)
        await h.instruction(0xac00|groups);await h.instruction(0xb000|columns)
        await h.instruction(0xb800|batches)
        ready=int(d.perf_total_cycles.value);reads=int(d.flash_read_ops.value)
        await h.instruction(0xb403);await h.sync()
        after=[int(d.perf_total_cycles.value),int(d.perf_dma_cycles.value),int(d.perf_micro_cycles.value)]
        assert not int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==reads+columns
        row={'batch':batches,'columns':columns,'groups':groups,'macs':2*groups*columns*batches,
             'dma_cycles':after[1]-before[1],'micro_cycles_including_dma':after[2]-before[2],
             'host_setup_run_sync_cycles':after[0]-before[0],
             'host_run_sync_cycles':after[0]-ready,'flash_read_transactions':columns}
        rows.append(row);d._log.info('AUTO DMA %s',row)
    out=Path(os.environ.get('PERF_OUTPUT','/tmp/acc-auto-dma-perf/measurements.json'))
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps({'clock_assumption_hz':50_000_000,'uart_divider':h.period,
                              'scope':'Synthetic active inputs; input/output initialization excluded; not full EGRU',
                              'rows':rows},indent=2)+'\n')
