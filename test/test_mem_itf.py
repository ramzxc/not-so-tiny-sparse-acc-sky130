import random
import cocotb
from cocotb.triggers import Timer
from test_fp16_exec import add, vector, fp

@cocotb.test()
async def local_sram(d):
    async def tick():
        d.clk.value=0
        await Timer(50,unit='ns')
        d.clk.value=1
        await Timer(50,unit='ns')
    async def reset():
        d.rst_n.value=0;d.read_en.value=0;d.write_en.value=0;d.write_accumulate.value=0
        d.addr.value=0;d.device.value=1;d.write_data.value=0
        d.read_burst.value=0;d.read_continue.value=0
        d.qspi_req_rdy.value=0;d.qspi_read_data.value=0;d.qspi_read_data_val.value=0
        for _ in range(3):await tick()
        d.rst_n.value=1
        await tick()
    async def request(addr,data=None,acc=False,device=1):
        assert int(d.rdy.value)
        d.addr.value=addr;d.device.value=device;d.write_data.value=data or 0
        d.read_en.value=data is None;d.write_en.value=data is not None;d.write_accumulate.value=acc
        await tick()
        d.read_en.value=0;d.write_en.value=0;d.write_accumulate.value=0
        for _ in range(20):
            assert not int(d.qspi_req_val.value),'Local or invalid request escaped to Flash'
            if data is None and int(d.read_data_val.value):return int(d.read_data.value)
            if data is not None and int(d.rdy.value):return
            await tick()
        raise AssertionError('Local memory request did not complete')
    await reset()
    rng=random.Random(71);expected=[rng.getrandbits(32) for _ in range(128)]
    for i,data in enumerate(expected):await request(i*4,data)
    for i,data in enumerate(expected):assert await request(i*4)==data
    for i in range(0,128,2):
        a=vector(fp(i/8),fp(-i/4));b=vector(fp(1.5),fp(2))
        await request(i*4,a);await request(i*4,b,True)
        assert await request(i*4)==vector(add(a&65535,b&65535),add(a>>16,b>>16))
        assert await request((i+1)*4)==expected[i+1]
    snapshot=await request(0)
    for addr,dev in [(2,1),(509,1),(512,1),(0xffffff,1),(0,2),(0,3)]:
        await reset();assert await request(addr,device=dev)==0
        assert int(d.error.value)
        await request(addr,0xdeadbeef,device=dev)
        assert await request(0)==snapshot
    await reset()
    # Invalid Flash vector must be rejected before wrapping to address zero.
    assert await request(0xfffffd,device=0)==0
    assert int(d.error.value)
    await reset()
    # Reset an accepted read-modify-write before the write can reach the macro.
    d.addr.value=0;d.write_data.value=0xdeadbeef;d.write_en.value=1
    await tick();await reset()
    assert await request(0)==snapshot
    d._log.info('PASS all 128 vectors, neighboring halves, FP16 accumulation, bounds and reset')
