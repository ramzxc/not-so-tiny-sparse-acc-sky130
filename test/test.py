"""Exercise every physical SRAM row through the public wrapper pins."""
import random
import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def all_rows_roundtrip(dut):
    dut.clk.value = 0
    dut.rst_n.value = 0
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0

    async def cycle():
        # Slow enough for the functional GL model and macro output delay.
        await Timer(50, unit="ns")
        dut.clk.value = 1
        await Timer(50, unit="ns")
        dut.clk.value = 0
        await Timer(50, unit="ns")

    async def load_buffer(word):
        dut.ui_in.value = 0
        for lane in reversed(range(8)):
            dut.uio_in.value = (word >> (8 * lane)) & 255
            await cycle()

    async def write_word(address, word):
        await load_buffer(word)
        dut.ui_in.value = 0xC0 | address
        await cycle()
        dut.ui_in.value = 0

    async def read_word(address):
        dut.ui_in.value = 0x80 | address
        word = 0
        for lane in range(8):
            dut.uio_in.value = lane
            await cycle()
            word |= int(dut.uo_out.value) << (8 * lane)
            assert int(dut.uio_oe.value) == 0
            assert int(dut.uio_out.value) == 0
        dut.ui_in.value = 0
        return word

    await cycle()
    await cycle()
    dut.rst_n.value = 1
    rng = random.Random(512)
    expected = [rng.getrandbits(64) for _ in range(64)]
    # Both address directions catch aliasing and stale read data.
    for address, word in enumerate(expected):
        await write_word(address, word)
    for address in reversed(range(64)):
        assert await read_word(address) == expected[address], f"initial row {address}"
    for address in reversed(range(64)):
        expected[address] ^= (1 << 64) - 1
        await write_word(address, expected[address])
    for address in range(64):
        assert await read_word(address) == expected[address], f"overwrite row {address}"

    # A selected write must be suppressed while the design is disabled/reset.
    for gate in ["ena", "rst_n"]:
        await load_buffer(0)
        getattr(dut, gate).value = 0
        dut.ui_in.value = 0xC0 | 17
        await cycle()
        await cycle()
        dut.ui_in.value = 0
        getattr(dut, gate).value = 1
        assert await read_word(17) == expected[17], f"{gate} changed SRAM"
    dut._log.info("PASS: all 64 rows/512 bytes, overwrite, reset and enable isolation")
