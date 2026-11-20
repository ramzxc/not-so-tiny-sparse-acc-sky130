"""50 MHz functional gate simulation through package pins; no RTL backdoors.

The SRAM is its supplied behavioral macro model. No SDF is annotated, so this
checks post-route connectivity/function, not timing signoff.
"""
import json
import os
from pathlib import Path
import cocotb
from test_psram_stream import StreamHost

class GateHost(StreamHost):
    half_period_ns = 10

    def __init__(self, dut):
        super().__init__(dut)
        self.period = 87

@cocotb.test()
async def routed_programs_and_batch(d):
    h = GateHost(d)
    cases = json.loads(Path(os.environ['STREAM_FIXTURE']).with_suffix('.json').read_text())
    for case in cases:
        if case['name'] not in ('multiply', 'micro_batch_1', 'micro_batch_3'):
            continue
        await h.reset()
        await h.configure(case['base'], case['words'], len(case['payload']))
        r0, w0 = int(d.reads.value), int(d.writes.value)
        for _ in range(2):
            await h.frame(case['payload'])
            await h.done()
            for i in range(0, len(case['expected']), 2):
                await h.inspect(0x3000+i, case['expected'][i] | case['expected'][i+1] << 8)
        assert int(d.reads.value) > r0
        assert int(d.writes.value) > w0
        d.ena.value = 0
        await h.cycles(2)
        assert int(d.uio_oe.value) == 0
        d.ena.value = 1

@cocotb.test()
async def routed_raw_input_queue(d):
    h = GateHost(d)
    case = json.loads(Path(os.environ['STREAM_FIXTURE']).with_suffix('.json').read_text())[0]
    await h.reset()
    await h.configure(case['base'], case['words'], 2)
    await h.instruction(0xf400)
    w0 = int(d.writes.value)
    for byte in (0x38, 0x40, 0x40, 0x38):
        for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            h.pins = (h.pins & ~8) | (bit << 3)
            d.ui_in.value = h.pins
            await h.cycles(h.period)
    for _ in range(100000):
        if int(d.writes.value) >= w0 + 4:
            break
        await h.cycles()
    else:
        raise AssertionError('raw frames did not drain through PSRAM')
    await h.cycles(500)
    assert int(d.uo_out.value) & 2 == 0
    await h.inspect(0x400000, 0x4038)
    await h.inspect(0x400100, 0x3840)
    await h.inspect(0x3000, 0x4448)
