"""Control-word bit patterns are data outside the command phase."""
import cocotb
from test_psram_stream import StreamHost
from test_psram_queue import QueueHost


@cocotb.test()
async def framed_control_words_then_raw(d):
    h = QueueHost(d)
    await h.reset()
    # A one-word NOP program isolates byte preservation from arithmetic.
    words = (0xf400, 0xf100, 0xf200, 0xf300, 0xf100, 0xf400)
    payload = [byte for word in words for byte in (word & 255, word >> 8)]
    await h.configure(0x7ffffe, 1, len(payload))
    for _ in range(2):
        await h.frame(payload)
        await h.done()
        assert not int(d.uo_out.value) & 6
        assert (int(d.sram_snapshot.value) >> (768*8)) & ((1 << (len(payload)*8))-1) == int.from_bytes(bytes(payload), 'little')
    # Payload F100 must not poison configuration needed by the next F400 command.
    await h.instruction(0xf400)
    await h.cycles(10)
    assert int(d.uo_out.value) & 4
    before = int(d.completed.value)
    for word in words:
        await h.raw(word)
    for _ in range(5000):
        if int(d.completed.value) == before + 1:
            break
        await h.cycles()
    else:
        raise AssertionError('raw sentinel frame did not complete')
    assert not int(d.uo_out.value) & 2
    for i, word in enumerate(words):
        await h.inspect(0x400000+2*i, word)


@cocotb.test()
async def stream_configuration_bounds(d):
    h = StreamHost(d)
    for size in (0, 257):
        await h.reset()
        await h.configure(0x7ffffe, 1, size, 0)
        await h.instruction(0xf400)
        await h.cycles(20)
        assert int(d.uo_out.value) & 2
        assert not int(d.uo_out.value) & 4
    # F400 before configuration must fail rather than start an empty ring.
    await h.reset()
    await h.instruction(0xf400)
    await h.cycles(20)
    assert int(d.uo_out.value) & 2
    assert not int(d.uo_out.value) & 4


@cocotb.test()
async def full_slot_and_reconfiguration(d):
    h = QueueHost(d)
    await h.reset()
    await h.configure(0x7ffffe, 1, 2)
    await h.configure(0x7ffffe, 1, 256)
    await h.instruction(0xf400)
    await h.cycles(10)
    for i in range(128):
        await h.raw(0xf400 | i)
    for _ in range(30000):
        if int(d.completed.value) == 1:
            break
        await h.cycles()
    else:
        raise AssertionError('256-byte frame did not complete')
    assert not int(d.uo_out.value) & 2
    expected = sum((0xf400 | i) << (16*i) for i in range(128))
    assert int(d.sram_snapshot.value) >> (768*8) == expected
