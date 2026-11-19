"""Pin-level Flash burst: stalls, transaction boundaries, abort and reset."""
import random
import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def burst_reads(d):
    rng=random.Random(608)
    cycles=0
    async def tick(n=1):
        nonlocal cycles
        for _ in range(n):
            d.clk.value=0;await Timer(5,unit='ns')
            d.clk.value=1;await Timer(5,unit='ns');cycles+=1
    async def reset():
        d.rst_n.value=0;d.req_val.value=0;d.req_write.value=0;d.req_continue.value=0
        d.abort_read.value=0;d.stuck_busy.value=0;d.req_addr.value=0;d.req_data.value=0
        await tick(2);d.rst_n.value=1;await tick()
        assert int(d.cs_n.value) and not int(d.sck.value)
    async def start(addr,more):
        assert int(d.req_rdy.value)
        d.req_addr.value=addr;d.req_continue.value=more;d.req_val.value=1
        await tick();d.req_val.value=0
    async def receive(addr,more):
        for _ in range(500):
            if int(d.read_data_val.value):break
            await tick()
        else:raise AssertionError('Flash read timed out')
        assert int(d.read_data.value)==((addr*37+11)^(addr>>1))&255
        assert bool(int(d.cs_n.value))==(not more)
    await reset()
    timings={}
    for base,count in [(3,1),(255,4),(4093,64),(0x800,512)]:
        before=int(d.read_ops.value);begin=cycles
        for i in range(count):
            if i:
                # No clock edges or CS release during arbitrary consumer stalls.
                for _ in range(rng.randrange(1,15)):
                    assert not int(d.cs_n.value) and not int(d.sck.value)
                    assert int(d.dq_oe.value)==0
                    await tick()
            await start(base+i,i<count-1);await receive(base+i,i<count-1)
        assert int(d.read_ops.value)==before+1
        timings[count]=cycles-begin
    # No-stall control comparison, same bytes and command profile.
    async def transfer(burst):
        begin=cycles;before=int(d.read_ops.value)
        for i in range(64):
            more=burst and i<63
            await start(0x100+i,more);await receive(0x100+i,more)
        assert int(d.read_ops.value)-before==(1 if burst else 64)
        return cycles-begin
    single=await transfer(False);burst=await transfer(True)
    assert burst<single//4
    d._log.info('64 bytes: single=%d cycles, burst=%d cycles (no consumer stalls)',single,burst)
    # Busy Flash must finish status polling before the one read transaction.
    d.stuck_busy.value=1;await tick();before=int(d.read_ops.value)
    await start(9,False);await tick(160)
    assert not int(d.read_data_val.value) and int(d.read_ops.value)==before
    d.stuck_busy.value=0;await receive(9,False)
    # Abort a paused stream, then a fresh request must send a new header/address.
    await start(42,True);await receive(42,True)
    d.abort_read.value=1;await tick(3)
    assert int(d.cs_n.value) and not int(d.sck.value) and not int(d.read_data_val.value)
    d.abort_read.value=0;await tick()
    await start(900,False);await receive(900,False)
    # Reset while reading header, payload, and waiting between bytes.
    for delay in (5,118,140):
        await start(100,True);await tick(delay);await reset()
        await start(600,False);await receive(600,False)
