"""Replay converted Bishop inputs/weights through UART, burst DMA and MICRO."""
import json
import os
from pathlib import Path
import cocotb
from test_fp8_serial import host, config

@cocotb.test()
async def converted_bishop_tiles(d):
    root=Path(__file__).resolve().parents[1]
    cases=json.loads(Path(os.environ.get('BISHOP_FP8_CASES',
                           str(root/'reports/fp8_1k/data/rtl_cases.json'))).read_text())
    h=host(d)
    for case in cases:
        await h.reset()
        # The 8-bit count field permits 255 vectors per DMA command.
        remaining=case['input_vectors'];offset=0
        while remaining:
            count=min(remaining,255)
            await h.dma_copy(case['input_source']+offset,offset,count)
            offset+=count*2;remaining-=count
        await h.dma_copy(case['bias_source'],800,case['groups']*case['batch'])
        await config(h,0,case['weight_source'],800,case['groups'],case['columns'],
                     batch=case['batch'],buffer=768)
        before=int(d.flash_read_ops.value)
        await h.instruction(0xb403);await h.fence()
        assert not int(d.uo_out.value)&2
        assert int(d.flash_read_ops.value)-before==case['active_columns']
        snapshot=int(d.perf_sram_snapshot.value)
        actual=[(snapshot>>(8*(800+i)))&255 for i in range(len(case['expected']))]
        assert actual==case['expected'],(case['dataset'],case['batch'],actual,case['expected'])
        d._log.info('%s batch=%d input_columns=%d output_start=%d: bit-exact',
                    case['dataset'],case['batch'],case['columns'],case['first_output'])
