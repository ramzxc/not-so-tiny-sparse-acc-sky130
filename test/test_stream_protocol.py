"""Address elision across low Flash addresses and Flash-input fallback."""
from pathlib import Path
import struct
import sys

import cocotb
from test_serial import Host

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from micro_schedule import restore_run


@cocotb.test()
async def low_address_and_flash_input(d):
    h = Host(d)
    samples = [[0,1,0], [0,0,2], [0,-2,0], [0,0,3]]
    for input_sram in (True, False):
        outputs = []
        for compact in (False, True):
            await h.reset()
            await h.dma_copy(0x600, 0, 8)
            await h.dma_copy(0xb00, 128, 8)
            await h.address(64); await h.instruction(0xbc00)
            await h.address(128); await h.instruction(0xa800)
            await h.address(0); await h.instruction(0xbc01)
            await h.instruction(0xac02); await h.instruction(0xb804)
            address = 0 if input_sram else 0x600
            for iteration in range(3):
                if compact:
                    high = 0 if input_sram and iteration else None
                    words = restore_run(address, 0x500, 3, input_sram=input_sram, staging_high=high)
                else:
                    words = [0x2000 | address, 0x3000, 0xa000 | int(input_sram),
                             0x2500, 0x3000, 0xa400, 0xb003, 0xb403]
                for word in words:
                    await h.instruction(word)
                if not compact:
                    await h.sync()
            if compact:
                await h.fence()
            assert not int(d.uo_out.value) & 2
            snapshot = int(d.perf_sram_snapshot.value)
            actual = []
            for group in range(2):
                for b, x in enumerate(samples):
                    expected = [3*sum(x[c]*(c*4+group*2+lane+1) for c in range(3)) for lane in range(2)]
                    bits = (snapshot >> (8*(128+4*(group*4+b)))) & 0xffffffff
                    assert bits == int.from_bytes(struct.pack('<ee',*expected),'little')
                    actual.append(bits)
            outputs.append(actual)
        assert outputs[0] == outputs[1]
