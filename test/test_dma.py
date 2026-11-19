"""Blocking DMA control: randomized memory latency, range checks and retirement."""
import random
import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def copy_control(d):
    rng=random.Random(601)
    async def tick():
        d.clk.value=0;await Timer(5,unit='ns')
        d.clk.value=1;await Timer(5,unit='ns')
    async def settle():await Timer(1,unit='ns')
    async def reset():
        d.rst_n.value=0;d.host_valid.value=0;d.host_inst.value=0
        d.core_ready.value=1;d.units_idle.value=1;d.staging_addr.value=0
        d.mem_ready.value=1;d.mem_read_valid.value=0;d.memory_error.value=0
        await tick();d.rst_n.value=1;await settle()
    async def cfg(word,addr=0):
        d.host_inst.value=word;d.staging_addr.value=addr;d.host_valid.value=1
        await settle();assert int(d.host_ready.value) and not int(d.core_valid.value)
        await tick();d.host_valid.value=0;await settle()
    for src,dst,count in [(3,4,1),(0xffc,0,128),(0x7ffffe,1022,1),(20,512,255),(0xffffff,508,0)]:
        await reset();await cfg(0xc000,src);await cfg(0xc400,dst);await cfg(0xc800|count)
        # A queued host operation cannot retire before the last write completes.
        d.host_inst.value=0xffff;d.host_valid.value=1
        i=0
        while i<count:
            chunk=min(count-i,4-((dst+2*i)//2)%4)
            d.mem_ready.value=0
            for _ in range(rng.randrange(1,7)):
                await settle()
                assert int(d.busy.value) and not int(d.host_ready.value) and not int(d.core_valid.value)
                assert not int(d.mem_write.value) and int(d.mem_read.value)
                assert int(d.mem_addr.value)==src+2*i
                assert int(d.mem_destination.value)==dst+2*i
                assert int(d.mem_vectors.value)==chunk
                await tick()
            d.mem_ready.value=1;await tick();d.mem_ready.value=0
            for _ in range(rng.randrange(1,10)):
                await settle()
                assert int(d.busy.value) and not int(d.mem_read.value)
                assert int(d.mem_addr.value)==src+2*i and int(d.mem_vectors.value)==chunk
                await tick()
            d.mem_read_valid.value=1;await tick();d.mem_read_valid.value=0;i+=chunk
        await settle()
        assert not int(d.busy.value) and not int(d.error.value)
        assert int(d.host_ready.value) and int(d.core_valid.value) and int(d.core_inst.value)==0xffff
    for src,dst,count in [(0x7fffff,0,1),(0x7ffffe,0,2),(0xffffff,0,1),(0xfffffe,0,2),(0,1022,2),(0,1024,0),(0,1,1),(0,1024,1)]:
        await reset();await cfg(0xc000,src);await cfg(0xc400,dst);await cfg(0xc800|count)
        assert int(d.error.value) and not int(d.busy.value) and not int(d.mem_read.value)
    for bad in (0xc001,0xc401,0xc900,0xcc00):
        await reset();await cfg(bad)
        assert int(d.error.value) and not int(d.busy.value)
    # Commands wait for earlier ordinary operations to drain.
    await reset();d.units_idle.value=0;d.host_inst.value=0xc801;d.host_valid.value=1
    for _ in range(3):
        await settle();assert not int(d.host_ready.value) and not int(d.busy.value);await tick()
    d.units_idle.value=1;await tick();d.host_valid.value=0
    assert int(d.busy.value)
    # Accepted memory request must drain on a fault; no later request is issued.
    await tick();d.mem_ready.value=0;d.memory_error.value=1
    for _ in range(3):
        await tick();assert int(d.busy.value) and not int(d.mem_read.value) and not int(d.mem_write.value)
    d.mem_ready.value=1;await tick();assert not int(d.busy.value) and int(d.error.value)
    # Reset cancels a stalled copy and clears the sticky error.
    await reset();await cfg(0xc801);d.mem_ready.value=0;await tick()
    await reset();assert not int(d.busy.value) and not int(d.error.value)
