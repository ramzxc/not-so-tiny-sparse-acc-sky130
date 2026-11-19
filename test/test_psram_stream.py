"""Actual UART input, QPI program/weights/output, bounded bursts and hazards."""
import json,os
from pathlib import Path
import cocotb
from test_serial import Host
class StreamHost(Host):
    def __init__(self,d):
        super().__init__(d);self.period=int(os.environ.get('PERF_UART_CLKS_PER_BIT','8'))
    async def reset(self):
        self.d.rst_n.value=0;self.d.ui_in.value=8;self.pins=8;self.d.ena.value=1;self.d.observe_addr.value=0
        self.credits=0;self.state=-1
        await self.cycles(8);assert int(self.d.uio_oe.value)==0
        self.d.rst_n.value=1;await self.cycles(8)
    async def configure(self,base,words,byte_count=0,input_base=768):
        for w in (0xf100,base&65535,base>>16,words,input_base,byte_count):await self.instruction(w)
    async def frame(self,payload):
        await self.instruction(0xf200 if payload else 0xf300)
        for i in range(0,len(payload),2):await self.instruction(payload[i]|((payload[i+1] if i+1<len(payload) else 0)<<8))
    async def done(self):
        await self.wait_credit();assert int(self.d.uo_out.value)&2==0
    async def inspect(self,address,expected):
        self.d.observe_addr.value=address;await self.cycles(1)
        assert int(self.d.observe_data.value)==expected,(hex(address),hex(int(self.d.observe_data.value)),hex(expected))

@cocotb.test()
async def programs_and_replay(d):
    h=StreamHost(d)
    cases=json.loads(Path(os.environ['STREAM_FIXTURE']).with_suffix('.json').read_text())
    for case in cases:
        await h.reset();await h.configure(case['base'],case['words'],len(case['payload']))
        f0=int(d.fetches.value)
        await h.frame(case['payload']);await h.done()
        assert int(d.fetches.value)-f0==(case['words']+3)//4
        for i in range(0,len(case['expected']),2):await h.inspect(0x3000+i,case['expected'][i]|case['expected'][i+1]<<8)
        if 'sram_expected' in case:
            assert int(d.sram_snapshot.value)==int.from_bytes(bytes(case['sram_expected']),'little')
        if case['payload']:
            snap=int(d.sram_snapshot.value)
            assert bytes((snap>>(8*(768+i)))&255 for i in range(len(case['payload'])))==bytes(case['payload'])
        # Same config replays from the start; no UART instruction stream.
        await h.frame(case['payload']);await h.done()
        for i in range(0,len(case['expected']),2):await h.inspect(0x3000+i,case['expected'][i]|case['expected'][i+1]<<8)
    assert int(d.data_wait_fetch.value)>0,'data must wait for instruction fetch'
    assert int(d.fetch_wait_data.value)>0,'instruction fetch must wait for data'

@cocotb.test()
async def framing_bounds_and_partial_input(d):
    h=StreamHost(d)
    # Last legal instruction is a two-byte read ending at 7fffff.
    await h.reset();await h.configure(0x7ffffe,1);await h.frame([]);await h.done()
    # Odd payload is padded with zero and never executes until complete.
    await h.reset();await h.configure(0x7ffffe,1,3,1020)
    await h.instruction(0xf200);f0=int(d.fetches.value)
    await h.instruction(0x1234);await h.cycles(100)
    assert int(d.fetches.value)==f0
    await h.instruction(0xff56);await h.done()
    assert int(d.sram_snapshot.value)>>(1020*8)==0x00561234
    for base,words,addr,size in [(0x7ffffe,2,768,0),(0x800000,1,768,0),(0x10001,1,768,0),(0x10000,0,768,0),(0x10000,1,1022,3),(0x10000,1,769,2)]:
        await h.reset();r0=int(d.reads.value);await h.configure(base,words,size,addr);await h.cycles(30)
        assert int(d.uo_out.value)&2;assert int(d.reads.value)==r0
    # DMA and ordinary MEM reject the complete out-of-range vector/span.
    for base,words in [(0x19000,8),(0x19100,5)]:
        await h.reset();await h.configure(base,words);await h.frame([]);await h.cycles(1500)
        assert int(d.uo_out.value)&2
    await h.reset();await h.instruction(0x1234);await h.cycles(20);assert int(d.uo_out.value)&2

@cocotb.test()
async def reset_during_qpi(d):
    h=StreamHost(d);await h.reset();await h.configure(0x10000,17,2)
    await h.frame([0x38,0x40])
    for _ in range(3000):
        if not int(d.uio_out.value)&64:break
        await h.cycles()
    else:raise AssertionError('no QPI transaction')
    d.rst_n.value=0;await h.cycles(1);assert int(d.uio_oe.value)==0
    await h.reset();await h.configure(0x7ffffe,1);await h.frame([]);await h.done()

@cocotb.test()
async def uart_framing_fault(d):
    h=StreamHost(d);await h.reset();await h.wait_credit();h.credits-=1
    # Bad stop bit must latch a fault, not turn a partial word into a command.
    for bit in [0]+[0]*8+[0]:
        h.pins=(h.pins&~8)|(bit<<3);d.ui_in.value=h.pins;await h.cycles(h.period)
    h.pins|=8;d.ui_in.value=h.pins;await h.cycles(h.period*3)
    assert int(d.uo_out.value)&2
    await h.reset();await h.configure(0x7ffffe,1);await h.frame([]);await h.done()
