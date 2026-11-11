"""DMA scoreboard under independent AXI/local stalls, including maximum lengths."""
import random
from collections import deque

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def dma_stress(d):
    rng = random.Random(0xD0A2)
    outputs_held = {}
    transfers = 0
    inputs = ['inst', 'inst_enable', 'dram_read_cmd_ready', 'dram_read_data',
              'dram_read_data_last', 'dram_read_data_valid', 'dram_write_cmd_ready',
              'dram_write_data_ready', 'dram_write_rsp_valid', 'weight_write_ready',
              'buffer_write_ready', 'acc_write_ready', 'buffer_read_req_ready',
              'acc_read_req_ready', 'buffer_read_rsp_data', 'buffer_read_rsp_valid',
              'acc_read_rsp_data', 'acc_read_rsp_valid']

    def put(name, value):
        getattr(d, name).value = value

    def get(name):
        return int(getattr(d, name).value)

    async def reset():
        outputs_held.clear()
        for name in inputs:
            put(name, 0)
        put('rst', 1)
        for _ in range(3):
            put('clk', 0)
            await Timer(5, unit='ns')
            put('clk', 1)
            await Timer(5, unit='ns')
        put('rst', 0)

    def check_stable(valid, ready, fields):
        payload = tuple(get(f) for f in fields)
        if valid in outputs_held:
            assert get(valid), f'{valid} dropped under backpressure'
            assert payload == outputs_held[valid], (valid, payload, outputs_held[valid])
        if get(valid) and not get(ready):
            outputs_held[valid] = payload
        else:
            outputs_held.pop(valid, None)

    async def transfer(opcode, length, start, stall_bias=.4):
        nonlocal transfers
        load = opcode in (0x40, 0x41, 0x44)
        target = {0x40: 'buffer', 0x41: 'weight', 0x44: 'acc',
                  0x42: 'buffer', 0x43: 'acc'}[opcode]
        base = 0 if target == 'acc' else 0x1234
        rows = [rng.getrandbits(32) for _ in range(length)]
        beats = [rows[i] | ((rows[i+1] if i+1 < length else 0) << 32)
                 for i in range(0, length, 2)]
        issued = done_beats = done_rows = requested_rows = 0
        active = None  # [first beat index, burst length, consumed beats]
        read_valid = False
        response_valid = False
        response_delay = 0
        pending_rows = deque()
        local_response = None
        for name in inputs:
            put(name, 0)
        put('inst', (start << 32) | (base << 16) | (length << 8) | opcode)
        put('inst_enable', 1)
        put('clk', 0)
        await Timer(5, unit='ns')
        put('clk', 1)
        await Timer(5, unit='ns')
        put('inst_enable', 0)
        for cycle in range(30000):
            put('clk', 0)
            put('dram_read_cmd_ready', active is None and rng.random() > stall_bias)
            put('dram_write_cmd_ready', active is None and rng.random() > stall_bias)
            put('dram_write_data_ready', active is not None and rng.random() > stall_bias)
            for port in ('weight', 'buffer', 'acc'):
                put(f'{port}_write_ready', rng.random() > stall_bias)
            for port in ('buffer', 'acc'):
                put(f'{port}_read_req_ready', rng.random() > stall_bias)
                put(f'{port}_read_rsp_valid', 0)
            if load and active is not None and not read_valid and rng.random() > stall_bias:
                read_valid = True
            put('dram_read_data_valid', read_valid)
            if read_valid:
                put('dram_read_data', beats[active[0]+active[2]])
                put('dram_read_data_last', active[2]+1 == active[1])
            if not load:
                if local_response is None and pending_rows and pending_rows[0][1] <= cycle:
                    local_response = pending_rows.popleft()[0]
                if local_response is not None:
                    put(f'{target}_read_rsp_valid', 1)
                    put(f'{target}_read_rsp_data', rows[local_response])
                if active is not None and active[2] == active[1]:
                    if response_delay:
                        response_delay -= 1
                    else:
                        response_valid = True
            put('dram_write_rsp_valid', response_valid)
            await Timer(5, unit='ns')
            for direction in ('read', 'write'):
                check_stable(f'dram_{direction}_cmd_valid', f'dram_{direction}_cmd_ready',
                             [f'dram_{direction}_cmd_addr', f'dram_{direction}_cmd_len'])
            check_stable('dram_write_data_valid', 'dram_write_data_ready',
                         ['dram_write_data', 'dram_write_strb', 'dram_write_data_last'])
            for port in ('weight', 'buffer', 'acc'):
                check_stable(f'{port}_write_valid', f'{port}_write_ready',
                             [f'{port}_write_addr', f'{port}_write_data'])
            for port in ('buffer', 'acc'):
                check_stable(f'{port}_read_req_valid', f'{port}_read_req_ready', [f'{port}_read_req_addr'])

            direction = 'read' if load else 'write'
            if get(f'dram_{direction}_cmd_valid') and get(f'dram_{direction}_cmd_ready'):
                assert active is None
                addr = (start + issued*8) & 0xFFFFFFFF
                count = min(len(beats)-issued, 32, (4096-(addr & 4095))//8)
                assert count > 0
                assert get(f'dram_{direction}_cmd_addr') == addr
                assert get(f'dram_{direction}_cmd_len') == count-1
                active = [issued, count, 0]
                issued += count
                response_delay = rng.randrange(1, 12)
            if load:
                if read_valid and get('dram_read_data_ready'):
                    active[2] += 1
                    done_beats += 1
                    read_valid = False
                    if active[2] == active[1]:
                        active = None
                if get(f'{target}_write_valid') and get(f'{target}_write_ready'):
                    assert done_rows < length
                    assert get(f'{target}_write_addr') == base + done_rows
                    assert get(f'{target}_write_data') == rows[done_rows]
                    done_rows += 1
            else:
                if get(f'{target}_read_req_valid') and get(f'{target}_read_req_ready'):
                    assert requested_rows < length
                    assert get(f'{target}_read_req_addr') == base + requested_rows
                    pending_rows.append((requested_rows, cycle+rng.randrange(1, 12)))
                    requested_rows += 1
                if local_response is not None and get(f'{target}_read_rsp_ready'):
                    local_response = None
                    done_rows += 1
                if get('dram_write_data_valid') and get('dram_write_data_ready'):
                    assert active is not None
                    assert get('dram_write_data') == beats[done_beats]
                    strobe = 15 if done_beats == len(beats)-1 and length % 2 else 255
                    assert get('dram_write_strb') == strobe
                    assert get('dram_write_data_last') == (active[2]+1 == active[1])
                    active[2] += 1
                    done_beats += 1
                if response_valid and get('dram_write_rsp_ready'):
                    active = None
                    response_valid = False
            put('clk', 1)
            await Timer(5, unit='ns')
            if not get('busy'):
                assert done_rows == length, (opcode, length, done_rows)
                assert done_beats == len(beats)
                assert issued == len(beats)
                assert active is None
                assert not pending_rows and local_response is None
                transfers += 1
                return
        assert False, ('DMA timeout', opcode, length, start, done_rows, done_beats)

    await reset()
    for length in (0, 1, 2, 3, 7, 8, 31, 32, 33, 63, 64, 65, 127, 128, 129, 254, 255):
        for start in (0x1000, 0x1FF8, 0x2FE0, 0xFFFFFFF8):
            for opcode in (0x40, 0x41, 0x44, 0x42, 0x43):
                await transfer(opcode, length, start)
    # Sustained heavy stalls and immediate LOAD/STORE direction changes.
    for _ in range(30):
        await transfer(rng.choice((0x40, 0x41, 0x44, 0x42, 0x43)),
                       rng.randrange(1, 256), rng.choice((0x1000, 0x1FF8)), .8)
    # Reset with an active command and confirm subsequent work recovers.
    put('inst', (0x1000 << 32) | (255 << 8) | 0x40)
    put('inst_enable', 1)
    put('clk', 0)
    await Timer(5, unit='ns')
    put('clk', 1)
    await Timer(5, unit='ns')
    assert get('busy')
    await reset()
    await transfer(0x40, 3, 0x1FF8)
    await transfer(0x42, 3, 0x1FF8)
    d._log.info('PASS: %d DMA transfers; max 255 rows, boundary splits, odd tails, stalls and reset', transfers)
