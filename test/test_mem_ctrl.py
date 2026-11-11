"""Shared single-port memory: arbitration, atomicity, stalls and capacity bounds."""
import os
import random
import struct

import cocotb
from cocotb.triggers import Timer


def packed(values, width):
    return sum(v << (i * width) for i, v in enumerate(values))


def half(value):
    return int.from_bytes(struct.pack('<e', value), 'little')


def add_rows(a, b):
    result = 0
    for shift in (0, 16):
        av = struct.unpack('<e', ((a >> shift) & 65535).to_bytes(2, 'little'))[0]
        bv = struct.unpack('<e', ((b >> shift) & 65535).to_bytes(2, 'little'))[0]
        result |= half(av + bv) << shift
    return result


@cocotb.test()
async def shared_memory_transactions(d):
    rng = random.Random(9147)
    size = int(os.environ['SRAM_BYTES'])
    limits = [size // 8, size // 16, size // 16]
    model = [[0] * n for n in limits]
    requests = [None] * 12
    expected = [None] * 12
    counts = [0] * 12
    held = [None] * 12
    d.clk.value = 0
    d.rst.value = 1

    async def cycle(ready=4095):
        d.clk.value = 0
        d.req_valid.value = sum((q is not None) << i for i, q in enumerate(requests))
        d.req_write.value = sum((q is not None and q[2]) << i for i, q in enumerate(requests))
        d.req_accumulate.value = sum((q is not None and q[4]) << i for i, q in enumerate(requests))
        d.req_region.value = packed([q[0] if q else 0 for q in requests], 2)
        d.req_addr.value = packed([q[1] if q else 0 for q in requests], 24)
        d.req_data.value = packed([q[3] if q else 0 for q in requests], 32)
        d.rsp_ready.value = ready
        await Timer(50, unit='ns')
        accepted = int(d.req_ready.value) & int(d.req_valid.value)
        assert accepted.bit_count() <= 1
        rv = int(d.rsp_valid.value)
        data = int(d.rsp_data.value)
        for i in range(12):
            if held[i] is not None:
                assert rv & (1 << i), 'response dropped under backpressure'
                assert (data >> (32*i)) & 0xFFFFFFFF == held[i]
            if rv & (1 << i):
                value = (data >> (32*i)) & 0xFFFFFFFF
                assert expected[i] is not None
                assert value == expected[i], (i, hex(value), hex(expected[i]))
                if ready & (1 << i):
                    expected[i] = None
                    held[i] = None
                else:
                    held[i] = value
            if accepted & (1 << i):
                region, addr, write, value, accumulate = requests[i]
                valid = region < 3 and addr < limits[region]
                if write and valid:
                    model[region][addr] = add_rows(model[region][addr], value) if accumulate else value
                elif not write:
                    assert expected[i] is None
                    expected[i] = model[region][addr] if valid else 0
                requests[i] = None
                counts[i] += 1
        d.clk.value = 1
        await Timer(50, unit='ns')

    for _ in range(3):
        await cycle()
    d.rst.value = 0

    async def drain():
        for _ in range(1000):
            await cycle()
            if not any(requests) and all(e is None for e in expected) and not int(d.busy.value):
                return
        assert False, 'memory transaction failed to drain'

    async def transact(region, addr, write=False, value=0, accumulate=False, client=0):
        requests[client] = (region, addr, write, value, accumulate)
        await drain()

    # Initialize both halves of every physical word. Distinct regions/rows.
    for region, length in enumerate(limits):
        for addr in range(length):
            value = half((addr % 8) + 1) | (half(region + 1) << 16)
            await transact(region, addr, True, value)

    # Stall one read response; other clients must still make progress.
    requests[0] = (0, 0, False, 0, False)
    for _ in range(8):
        await cycle(4094)
    assert held[0] is not None
    previous = counts[1]
    requests[1] = (2, 1, True, half(9) | (half(10) << 16), False)
    for _ in range(20):
        await cycle(4094)
    assert counts[1] == previous + 1
    await drain()

    # Fill both shared response slots. A third read must wait, but a write
    # must pass it. Releasing either slot must allow the waiting read through.
    for release_client, stalled_client in ((0, 2), (2, 0)):
        requests[0] = (0, 0, False, 0, False)
        requests[2] = (0, 1, False, 0, False)
        blocked_mask = 4095 & ~(1 << 0) & ~(1 << 2)
        for _ in range(12):
            await cycle(blocked_mask)
        assert held[0] is not None and held[2] is not None
        reads_before, writes_before = counts[3], counts[1]
        requests[3] = (0, 2, False, 0, False)
        requests[1] = (2, 1, True, 0x40003C00, False)
        for _ in range(20):
            await cycle(blocked_mask)
        assert counts[3] == reads_before, 'read accepted without a free response slot'
        assert counts[1] == writes_before + 1, 'full response slots blocked a write'
        for _ in range(16):
            await cycle(blocked_mask | (1 << release_client))
        assert counts[3] == reads_before + 1, 'released slot was not reused'
        assert held[stalled_client] is not None
        await drain()

    # Contending reads/writes, including ACC accumulation and random response stalls.
    for _ in range(6000):
        for i in range(12):
            if requests[i] is None and expected[i] is None and rng.random() < .35:
                region = rng.randrange(3)
                addr = rng.randrange(limits[region])
                write = rng.random() < .6
                value = half(rng.randrange(1, 33) / 8) | (half(rng.randrange(1, 33) / 8) << 16)
                requests[i] = (region, addr, write, value, write and region == 1 and rng.random() < .4)
        await cycle(rng.getrandbits(12))
    await drain()
    assert min(counts[1:]) > 50, counts
    assert not int(d.error.value)

    # Boundaries and high address bits may not alias another region.
    for region in range(3):
        await transact(region, limits[region], True, 0xDEADBEEF)
        await transact(region, limits[region])
        await transact(region, (1 << 23) + 1, True, 0xBAD0BAD0)
        await transact(region, limits[region] - 1)
    assert int(d.error.value)
    for region, length in enumerate(limits):
        for addr in range(length):
            await transact(region, addr)

    # Reset after write acceptance, before RMW commit: old contents survive.
    saved = model[0][0]
    requests[0] = (0, 0, True, 0x3C003C00, False)
    await cycle()
    assert requests[0] is None
    d.rst.value = 1
    await cycle()
    model[0][0] = saved
    d.rst.value = 0
    await transact(0, 0)
    assert not int(d.error.value)

    # Reset in either serialized accumulate phase must not commit half a row.
    for addr in (0, 1):
        for extra_cycles in (1, 2):
            saved = model[1][addr]
            requests[0] = (1, addr, True, 0x3C003C00, True)
            await cycle()
            assert requests[0] is None
            for _ in range(extra_cycles):
                await cycle()
            d.rst.value = 1
            await cycle()
            model[1][addr] = saved
            d.rst.value = 0
            await transact(1, addr)
            await transact(1, addr ^ 1)
            assert not int(d.error.value)
    # Reset must discard both stalled responses and make both slots reusable.
    requests[0] = (0, 0, False, 0, False)
    requests[2] = (0, 1, False, 0, False)
    for _ in range(12):
        await cycle(4090)
    assert held[0] is not None and held[2] is not None
    d.rst.value = 1
    await cycle(0)
    expected[:] = [None] * 12
    held[:] = [None] * 12
    assert int(d.rsp_valid.value) == 0
    d.rst.value = 0
    for client in range(12):
        await transact(0, client, client=client)
    d._log.info('PASS %s bytes: %s accepted transactions; all clients progressed', size, sum(counts))
