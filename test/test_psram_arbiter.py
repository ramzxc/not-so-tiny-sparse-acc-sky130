"""Exclusive transaction ownership with simultaneous requests and backpressure."""
import random
import cocotb
from cocotb.triggers import Timer
@cocotb.test()
async def ownership(d):
    async def tick():
        d.clk.value=0;await Timer(5,unit='ns');d.clk.value=1;await Timer(5,unit='ns')
    async def settle():await Timer(1,unit='ns')
    d.rst_n.value=0;d.data_valid.value=0;d.fetch_valid.value=0;d.data_write.value=0
    d.data_addr.value=0;d.fetch_addr.value=0;d.data_bytes.value=2;d.fetch_bytes.value=8
    d.data_wdata.value=0;d.req_ready.value=0;d.done.value=0;d.byte_valid.value=0
    await tick();d.rst_n.value=1
    rng=random.Random(4242)
    for i in range(80):
        # Data wins simultaneous requests; fetch stays pending across completion.
        a=rng.randrange(0x7ffff8);b=rng.randrange(0x7ffff8)
        d.data_valid.value=1;d.fetch_valid.value=1;d.data_addr.value=a;d.fetch_addr.value=b
        d.data_write.value=i%2;d.data_wdata.value=i;d.req_ready.value=0
        for _ in range(rng.randrange(1,5)):
            await settle();assert not int(d.data_ready.value) and not int(d.fetch_ready.value)
            assert int(d.req_valid.value) and int(d.req_addr.value)==a
            await tick()
        d.req_ready.value=1;await settle();assert int(d.data_ready.value) and not int(d.fetch_ready.value)
        await tick();d.data_valid.value=0
        for _ in range(rng.randrange(1,6)):
            d.byte_valid.value=1;await settle()
            assert int(d.data_byte_valid.value) and not int(d.fetch_byte_valid.value)
            assert not int(d.fetch_ready.value) and not int(d.req_valid.value)
            await tick()
        d.byte_valid.value=0;d.done.value=1;await settle()
        assert int(d.data_done.value) and not int(d.fetch_done.value)
        await tick();d.done.value=0;await settle()
        assert int(d.fetch_ready.value) and int(d.req_addr.value)==b and int(d.req_bytes.value)==8
        assert not int(d.req_write.value)
        await tick();d.fetch_valid.value=0;d.data_valid.value=1
        for _ in range(3):
            d.byte_valid.value=1;await settle();assert int(d.fetch_byte_valid.value) and not int(d.data_byte_valid.value)
            assert not int(d.data_ready.value);await tick()
        d.byte_valid.value=0;d.done.value=1;await settle()
        assert int(d.fetch_done.value) and not int(d.data_done.value)
        await tick();d.done.value=0;d.data_valid.value=0
    d.rst_n.value=0;await tick();assert not int(d.busy.value)
