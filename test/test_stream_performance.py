"""Same UART/RTL/arithmetic: compare fenced and streamed MICRO tile execution."""
import json
import os
from pathlib import Path
import struct
import sys

import cocotb
from test_serial import Host

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from micro_schedule import restore_run


@cocotb.test()
async def stream_equivalence(d):
    h = Host(d)
    h.period = int(os.environ.get('PERF_UART_CLKS_PER_BIT', '87'))
    cases = json.loads(Path(os.environ.get('PERF_CASES', '/tmp/acc-stream-eval/cases.json')).read_text())
    rows = []
    for case in cases:
        b, c, g = [case[k] for k in ('batch', 'columns', 'groups')]
        results = []
        for mode in ('baseline', 'stream', 'compact'):
            streaming = mode != 'baseline'
            await h.reset()
            await h.dma_copy(case['source'], 0, case['input_bytes']//4)
            # Initialize output through DMA; no SRAM backdoor writes.
            await h.dma_copy(0x7000, case['acc'], b*g)
            await h.address(case['buffer']); await h.instruction(0xbc00)
            await h.address(case['acc']); await h.instruction(0xa800)
            await h.address(0); await h.instruction(0xbc01)
            await h.instruction(0xac00 | g); await h.instruction(0xb800 | b)
            await h.sync()
            before = [int(d.perf_total_cycles.value), int(d.perf_micro_cycles.value),
                      int(d.perf_dma_cycles.value), int(d.flash_read_ops.value)]
            # Repeated accumulation preserves exact arithmetic ordering.
            for iteration in range(case['repeats']):
                known_high = 0 if mode == 'compact' and iteration else None
                columns = case.get('run_columns', [c]*case['repeats'])[iteration]
                for word in restore_run(0, 0x1000, columns, sparse=case['sparse'], staging_high=known_high):
                    await h.instruction(word)
                if not streaming:
                    await h.sync()
            if streaming:
                await h.fence()
            after = [int(d.perf_total_cycles.value), int(d.perf_micro_cycles.value),
                     int(d.perf_dma_cycles.value), int(d.flash_read_ops.value)]
            assert not int(d.uo_out.value) & 2
            active_columns = case['union_columns'] if case['sparse'] else c
            assert after[3]-before[3] == case.get('total_bursts', active_columns * case['repeats'])
            values = []
            snapshot = int(d.perf_sram_snapshot.value)
            for group in range(g):
                for sample in range(b):
                    address = case['acc'] + 4*(group*b+sample)
                    value = (snapshot >> (8*address)) & 0xffffffff
                    values.append(value)
                    # All weights are [.5, -.25]; sums are exactly representable.
                    n = case.get('total_active', [a*case['repeats'] for a in case['sample_active']])[sample]
                    expected = int.from_bytes(struct.pack('<ee', n*.5, -n*.25), 'little')
                    # Signed zero is checked between schedules below, but the
                    # integer oracle intentionally treats either zero sign alike.
                    if n:
                        assert value == expected, (case['name'], group, sample, hex(value), hex(expected))
                    else:
                        assert value & 0x7fff7fff == 0
            results.append((values, [a-z for a,z in zip(after, before)]))
        assert results[0][0] == results[1][0]
        assert results[0][0] == results[2][0]
        assert results[0][1][1:] == results[1][1][1:]
        assert results[0][1][1:] == results[2][1][1:]
        row = dict(case, baseline_cycles=results[0][1][0], stream_cycles=results[1][1][0],
                   compact_cycles=results[2][1][0],
                   micro_cycles=results[1][1][1], dma_cycles=results[1][1][2])
        rows.append(row)
        d._log.info('%s baseline=%d stream=%d compact=%d micro=%d', case['name'], row['baseline_cycles'],
                    row['stream_cycles'], row['compact_cycles'], row['micro_cycles'])
    out = Path(os.environ['PERF_OUTPUT'])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({'uart_divider': h.period, 'rows': rows}, indent=2)+'\n')
