"""Measure actual DMA/MICRO busy cycles; UART setup is reported separately.

Synthetic nonzero inputs measure scheduling cost, not EGRU accuracy. This test
uses the unchanged arithmetic, SRAM macro model and pin-level Flash model.
"""
import json
import os
from pathlib import Path
import cocotb
from test_serial import Host

@cocotb.test()
async def measure(d):
    h=Host(d);h.period=int(os.environ.get('PERF_UART_CLKS_PER_BIT','8'));await h.reset()
    result={'clock_assumption_hz':50_000_000,'uart_test_divider':h.period,
            'dma':[], 'micro':[]}
    def counters():
        return [int(d.perf_total_cycles.value),int(d.perf_dma_cycles.value),int(d.perf_micro_cycles.value)]
    for count in [1,4,16,32,64,128]:
        before=counters();reads=int(d.flash_read_ops.value)
        await h.dma_copy(0x800,0,count)
        after=counters()
        assert not int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==reads+1
        row={'bytes':4*count,'busy_cycles':after[1]-before[1],
             'host_sequence_cycles_test_uart':after[0]-before[0]}
        result['dma'].append(row);d._log.info('DMA %s',row)
    # Valid 512 B layout: input 0..3, weights 4..259, output 384..511.
    # Input [1,2], all partial sums zero, arbitrary FP16 weights (timing is fixed).
    await h.dma_copy(0,0,1)
    await h.dma_copy(0x800,4,64)
    for a in range(384,512,4):await h.dma_copy(12,a,1)
    for groups,columns in [(1,1),(8,1),(16,1),(32,1),(32,2)]:
        for zero in (False,True):
            await h.dma_copy(12 if zero else 0,0,1)
            await h.address(0);await h.instruction(0xa001)
            await h.address(4);await h.instruction(0xa401)
            await h.address(384);await h.instruction(0xa800)
            await h.instruction(0xac00|groups);await h.instruction(0xb000|columns)
            before=counters();reads=int(d.flash_read_ops.value)
            await h.instruction(0xb401);await h.sync()
            after=counters()
            assert not int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==reads
            row={'groups':groups,'columns':columns,'zero':zero,
                 'macs':0 if zero else 2*groups*columns,
                 'busy_cycles':after[2]-before[2],
                 'host_run_sync_cycles_test_uart':after[0]-before[0]}
            result['micro'].append(row);d._log.info('MICRO %s',row)
    # A concrete host-driven batch=1 tile: 64 outputs, one active input.
    # Keep input/output on chip. Reconfigure consumed DMA/MICRO pointers each run.
    # Deliberately omit the intermediate host SYNC: ownership already orders DMA.
    await h.dma_copy(0,0,1)
    await h.address(384);await h.instruction(0xa800)
    await h.instruction(0xac20)
    before=counters()
    await h.address(0x800);await h.instruction(0xc000)
    await h.address(4);await h.instruction(0xc400)
    await h.instruction(0xc820)
    await h.address(0);await h.instruction(0xa001)
    await h.address(4);await h.instruction(0xa401)
    await h.instruction(0xb001);await h.instruction(0xb401);await h.sync()
    after=counters()
    assert not int(d.uo_out.value)&2
    result['host_tile']={'macs':64,'weight_bytes':128,'instruction_words':18,
                         'cycles':after[0]-before[0],
                         'dma_busy_cycles':after[1]-before[1],
                         'micro_busy_cycles':after[2]-before[2],
                         'excluded':'input delivery, output initialization/spill, activation, result readback'}
    d._log.info('HOST TILE %s',result['host_tile'])
    out=Path(os.environ.get('PERF_OUTPUT','/tmp/acc-throughput/measurements.json'))
    out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(result,indent=2)+'\n')
