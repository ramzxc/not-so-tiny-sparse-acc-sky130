# SPI pin-level integration tests. No hierarchical access to the accelerator.
import cocotb
from cocotb.triggers import Timer


class Host:
    def __init__(self, dut):
        self.dut = dut
        self.pins = 2

    async def cycles(self, n=1):
        for _ in range(n):
            self.dut.clk.value = 0
            await Timer(50, unit='ns')
            self.dut.clk.value = 1
            await Timer(50, unit='ns')

    async def reset(self):
        self.dut.ena.value = 1
        self.dut.rst_n.value = 0
        self.dut.ui_in.value = 2
        self.dut.uio_in.value = 0
        await self.cycles(8)
        self.dut.rst_n.value = 1
        await self.cycles(8)

    async def byte(self, value):
        result = 0
        for bit in range(7, -1, -1):
            self.pins = (self.pins & 2) | (((value >> bit) & 1) << 2)
            self.dut.ui_in.value = self.pins
            await self.cycles(5)
            result = (result << 1) | (int(self.dut.uio_out.value) & 1)
            self.dut.ui_in.value = self.pins | 1
            await self.cycles(5)
        self.dut.ui_in.value = self.pins
        await self.cycles(5)
        return result

    async def transaction(self, command, data=0):
        self.pins = 0
        self.dut.ui_in.value = 0
        await self.cycles(5)
        assert int(self.dut.uio_oe.value) == 1
        await self.byte(command)
        result = await self.byte(data)
        self.pins = 2
        self.dut.ui_in.value = 2
        await self.cycles(5)
        assert int(self.dut.uio_oe.value) == 0
        return result

    async def read(self, addr):
        return await self.transaction(addr)

    async def write(self, addr, data):
        await self.transaction(0x40 | addr, data)

    async def action(self, mask):
        await self.transaction(0x80, mask)

    async def instruction(self, word):
        assert not ((await self.read(0)) & 0x10)
        for i in range(8):
            await self.write(i, (word >> (8*i)) & 255)
        await self.action(0x20)

    async def wait_status(self, mask):
        for _ in range(100):
            status = await self.read(0)
            assert not (status & 0xC0), f'Error status: {status:02x}'
            if status & mask:
                return status
        raise AssertionError(f'Timeout waiting for status {mask:02x}')

    async def read_word(self, addr, size):
        value = 0
        for i in range(size):
            value |= (await self.read(addr+i)) << (8*i)
        return value

    async def response(self, word, last=True, resp=0, rid=0):
        assert not ((await self.read(1)) & 1)
        for i in range(8):
            await self.write(8+i, (word >> (8*i)) & 255)
        await self.write(16, (int(last) << 6) | (resp << 4) | rid)
        await self.action(8)


@cocotb.test()
async def test_spi_dma_roundtrip(dut):
    h = Host(dut)
    await h.reset()
    assert await h.read(63) == 0xA1
    assert await h.read(0) == 8
    # Abort an incomplete write; no command may be submitted.
    h.pins = 0
    dut.ui_in.value = 0
    await h.cycles(5)
    await h.byte(0x80)
    dut.ui_in.value = 2
    await h.cycles(8)
    assert await h.read(0) == 8
    # SYNC is sticky and explicitly clearable.
    await h.instruction(0xFF)
    await h.wait_status(0x20)
    await h.action(0x40)
    assert not ((await h.read(0)) & 0x20)
    # Two-row DRAM -> UB -> DRAM round trip, including AXI backpressure.
    words = [0x4400420040003C00, 0xC400C200C000BC00]
    await h.instruction((0x1000 << 32) | (2 << 8) | 0x40)
    await h.wait_status(4)
    assert await h.read_word(9, 4) == 0x1000
    assert await h.read(13) == 1
    ar_meta = await h.read(14)
    assert ar_meta & 7 == 3
    assert await h.read(15) == 1
    await h.cycles(100)
    assert await h.read_word(9, 4) == 0x1000
    await h.action(4)
    for i, word in enumerate(words):
        await h.response(word, last=i == len(words)-1, rid=ar_meta >> 4)
    await h.instruction((0x2000 << 32) | (2 << 8) | 0x42)
    await h.wait_status(1)
    assert await h.read_word(2, 4) == 0x2000
    assert await h.read(6) == 1
    aw_meta = await h.read(7)
    assert aw_meta & 7 == 3
    await h.action(1)
    for i, word in enumerate(words):
        await h.wait_status(2)
        assert await h.read_word(16, 8) == word
        assert await h.read(24) == 255
        assert await h.read(25) == int(i == len(words)-1)
        await h.cycles(20)
        assert await h.read_word(16, 8) == word
        await h.action(2)
    await h.write(17, aw_meta >> 4)
    await h.action(16)
    await h.instruction(0xFF)
    await h.wait_status(0x20)
    # Exercise FP16 vector arithmetic and the accumulator memory via SPI.
    await h.action(0x40)
    await h.instruction(0x108)  # WEIGHT from UB row 0 (is_unified=1)
    await h.instruction((3 << 16) | (1 << 8) | 0x22)  # UB[0]+UB[0] -> ACC[3]
    await h.instruction((0x3000 << 32) | (3 << 16) | (1 << 8) | 0x43)
    await h.wait_status(1)
    assert await h.read_word(2, 4) == 0x3000
    aw_meta = await h.read(7)
    await h.action(1)
    await h.wait_status(2)
    assert await h.read_word(16, 8) == 0x4800460044004000  # [2,4,6,8]
    assert await h.read(25) == 1
    await h.action(2)
    await h.write(17, aw_meta >> 4)
    await h.action(16)
    await h.instruction(0xFF)
    await h.wait_status(0x20)
    # Invalid acknowledgement is visible, clearable, and reset recovers state.
    await h.action(4)
    assert (await h.read(0)) & 0x80
    await h.action(0x80)
    assert not ((await h.read(0)) & 0x80)
    dut.ena.value = 0
    await h.cycles(8)
    assert int(dut.uio_oe.value) == 0
    dut.ena.value = 1
    await h.cycles(8)
    assert await h.read(63) == 0xA1
    assert await h.read(0) == 8
