"""No host credits after stream enable; exercise receive/execute overlap."""
import json,os
from pathlib import Path
import cocotb
from test_psram_stream import StreamHost
from fp8_reference import mul8

class QueueHost(StreamHost):
    async def raw(self,word):
        for byte in (word&255,word>>8):
            for bit in [0]+[(byte>>i)&1 for i in range(8)]+[1]:
                self.d.ui_in.value=bit<<3
                await self.cycles(self.period)
    async def enable(self,case,length=None):
        await self.reset()
        await self.configure(case['base'],case['words'],len(case['payload']) if length is None else length)
        await self.instruction(0xf400)
        await self.cycles(10)
        assert int(self.d.uo_out.value)&4
        assert not int(self.d.uo_out.value)&2

def cases():return json.loads(Path(os.environ['STREAM_FIXTURE']).with_suffix('.json').read_text())

@cocotb.test()
async def queue_overlaps_and_wraps(d):
    h=QueueHost(d);case=cases()[0]
    await h.enable(case)
    # Small test ring wraps repeatedly; fixed-rate producer does not use READY.
    seen=0;peak=0;sent=0
    for frame in range(12):
        payload=[0x38+(frame%4)*8,0x40]
        await h.raw(payload[0]|payload[1]<<8);sent+=1
        # Inspect every completion before the next program overwrites its result.
        for _ in range(1200):
            await h.cycles()
            peak=max(peak,int(d.queue_count.value))
            now=int(d.completed.value)
            if now!=seen:
                assert now==seen+1
                await h.inspect(0x3000,mul8(0x38+(seen%4)*8,0x40)|(mul8(0x40,0x44)<<8))
                seen=now
            assert not int(d.uo_out.value)&2
    for _ in range(100000):
        if int(d.completed.value)==sent:break
        await h.cycles()
        now=int(d.completed.value)
        if now!=seen:
            await h.inspect(0x3000,mul8(0x38+(seen%4)*8,0x40)|(mul8(0x40,0x44)<<8));seen=now
        assert not int(d.uo_out.value)&2
    assert int(d.completed.value)==sent
    assert int(d.queue_count.value)==0
    assert int(d.queue_write_slot.value)==0 # 12 frames / four slots
    assert peak>0

@cocotb.test()
async def incomplete_frame_and_odd_padding(d):
    h=QueueHost(d);await h.enable(cases()[0],3)
    await h.raw(0x4038);await h.cycles(1000)
    assert int(d.completed.value)==0 and int(d.queue_count.value)==0
    await h.raw(0xff56)
    for _ in range(5000):
        await h.cycles()
        if int(d.completed.value):break
    assert int(d.completed.value)==1
    snap=int(d.sram_snapshot.value)
    assert (snap>>(768*8))&0xffffffff==0x00564038
    assert not int(d.uo_out.value)&2

@cocotb.test()
async def queue_full_is_explicit_and_reset_recovers(d):
    h=QueueHost(d)
    # A deliberately faster producer fills the four-slot ring while the program runs.
    case=cases()[0]
    await h.reset();await h.configure(case['base'],case['words'],2)
    await h.instruction(0xf400);await h.cycles(10)
    for _ in range(20):
        if int(d.uo_out.value)&2:break
        await h.raw(0x4038)
    assert int(d.uo_out.value)&2,'overload must be reported, not overwrite old frames'
    assert int(d.queue_count.value)==4
    # Error is sticky and reset clears stream state and returns legacy operation.
    await h.cycles(100);assert int(d.uo_out.value)&2
    await h.reset();await h.cycles(20)
    assert not int(d.uo_out.value)&6 and int(d.queue_count.value)==0
