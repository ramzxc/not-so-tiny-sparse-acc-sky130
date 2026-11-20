"""Tiny UART -> decoder/data/exec -> SRAM or real QSPI Flash pins."""
import os
import cocotb
from cocotb.triggers import Timer

class Host:
    half_period_ns = 50
    def __init__(self,d):
        self.d=d;self.pins=8;self.credits=0;self.state=-1;self.counter=0;self.byte=0
        self.period=87 if os.environ.get('GATES')=='yes' else 8
    async def cycles(self,n=1):
        for _ in range(n):
            self.d.clk.value=0
            await Timer(self.half_period_ns,unit='ns')
            self.d.clk.value=1
            await Timer(self.half_period_ns,unit='ns')
            # UART observes TX only; READY is not valid for an empty FIFO head.
            tx=int(self.d.uo_out.value[4])
            if self.state==-1:
                if not tx:self.state=0;self.counter=self.period+self.period//2;self.byte=0
            else:
                self.counter-=1
                if not self.counter:
                    if self.state<8:
                        self.byte|=tx<<self.state;self.state+=1;self.counter=self.period
                    else:
                        assert tx and self.byte==1, 'Invalid 8N1 READY frame'
                        self.credits+=1;self.state=-1
    async def reset(self):
        self.d.rst_n.value=0;self.d.ena.value=1;self.d.flash_stuck_busy.value=0
        self.d.flash_observe_addr.value=0;self.d.observe_upper.value=0;self.pins=8;self.d.ui_in.value=8
        await self.cycles(8)
        self.credits=0;self.state=-1
        self.d.rst_n.value=1
        await self.cycles(8)
    async def wait_credit(self):
        for _ in range(200000): # full 512 B DMA can hold dispatch for >64k cycles
            if self.credits:break
            await self.cycles()
        else:raise AssertionError('UART credit timeout')
    async def instruction(self,word):
        await self.wait_credit()
        self.credits-=1
        for byte in [word&255,word>>8]:
            for bit in [0]+[(byte>>i)&1 for i in range(8)]+[1]:
                self.pins=(self.pins&~8)|(bit<<3);self.d.ui_in.value=self.pins
                await self.cycles(self.period)
    async def sync(self):
        # With depth two, credit for the second NOP proves preceding SYNC retired.
        for word in [0xffff,0,0]:await self.instruction(word)
        await self.cycles(8)
    async def fence(self):
        # The READY following the first NOP proves preceding SYNC retired.
        # Keep that credit for the next real command instead of sending a NOP.
        await self.instruction(0xffff)
        await self.instruction(0)
        await self.wait_credit()
    async def address(self,address):
        await self.instruction(0x2000|(address&4095));await self.instruction(0x3000|(address>>12))
    async def load(self,address,device=0,weight=False,sparse=False):
        await self.instruction(0x8000|(int(weight)<<10)|(int(sparse)<<11))
        await self.address(address);await self.instruction(0x4000|(device<<10))
    async def dma_copy(self,source,destination,vectors):
        await self.address(source);await self.instruction(0xc000)
        await self.address(destination);await self.instruction(0xc400)
        await self.instruction(0xc800|vectors);await self.sync()
    async def execute(self,op=2,act=0):
        await self.instruction(0x6000|(op<<10)|(act<<7));await self.sync()
    async def store(self,address,device=1,accumulate=False):
        await self.instruction(0x9000);await self.address(address)
        await self.instruction(0x5000|(device<<10)|(int(accumulate)<<9));await self.sync()
    async def inspect(self,address,expected):
        self.d.flash_observe_addr.value=address;await self.cycles(1)
        assert int(self.d.flash_observe_data.value)==expected,(hex(address),hex(int(self.d.flash_observe_data.value)),hex(expected))
    async def copy_sram_to_flash(self,source,dest):
        await self.load(source,1);await self.load(20,weight=True);await self.sync()
        await self.execute();await self.store(dest,0)

@cocotb.test()
async def tiny_framework_with_fp16_sram(d):
    h=Host(d);await h.reset()
    await h.load(0);await h.load(4,weight=True);await h.sync()
    await h.execute();await h.store(0);await h.store(4)
    await h.store(0,accumulate=True)
    await h.copy_sram_to_flash(0,0x1000);await h.inspect(0x1000,0x4c004600)
    await h.copy_sram_to_flash(4,0x1010);await h.inspect(0x1010,0x48004200)
    await h.store(508);await h.copy_sram_to_flash(508,0x1020);await h.inspect(0x1020,0x48004200)
    assert not int(d.uo_out.value)&2
    # Sparse full-vector zero suppresses the QSPI transaction completely.
    await h.load(12);await h.sync();before=int(d.flash_read_ops.value)
    await h.load(0xfffffc,weight=True,sparse=True);await h.sync()
    assert int(d.flash_read_ops.value)==before
    await h.execute();await h.store(8)
    await h.copy_sram_to_flash(8,0x1030);await h.inspect(0x1030,0x80000000) # FP16 preserves the negative-zero sign
    # A nonzero FP16 subnormal must read all four weight bytes.
    await h.load(16);await h.sync();before=int(d.flash_read_ops.value)
    await h.load(4,weight=True,sparse=True);await h.sync()
    assert int(d.flash_read_ops.value)==before+4
    await h.execute();await h.store(0x1040,0);await h.inspect(0x1040,0x00000300)
    # SRAM contents survive core reset; no backdoor SRAM preload was used.
    await h.reset();await h.copy_sram_to_flash(4,0x1050);await h.inspect(0x1050,0x48004200)
    # Invalid SRAM write cannot overwrite the low address by truncation.
    await h.store(512);assert int(d.uo_out.value)&2
    await h.reset();await h.copy_sram_to_flash(0,0x1060);await h.inspect(0x1060,0x4c004600)
    d._log.info('PASS tiny UART/QSPI path, FP16, flat SRAM, RMW accumulation, sparse and reset')

@cocotb.test()
async def mem_postincrement(d):
    h=Host(d);await h.reset()
    # Read input at Flash 0, then weight at Flash 4 without a second ADDR.
    await h.instruction(0x8000);await h.address(0)
    await h.instruction(0x4100);await h.instruction(0x8400)
    await h.instruction(0x4100);await h.sync();await h.execute()
    # Store the same result to adjacent vectors, then accumulate in both.
    await h.instruction(0x9000);await h.address(64)
    await h.instruction(0x5500);await h.instruction(0x5500);await h.sync()
    await h.address(64)
    await h.instruction(0x5700);await h.instruction(0x5700);await h.sync()
    await h.copy_sram_to_flash(64,0x1100);await h.inspect(0x1100,0x4c004600)
    await h.copy_sram_to_flash(68,0x1110);await h.inspect(0x1110,0x4c004600)
    # Read SRAM consecutively, selecting input then weight without another ADDR.
    await h.instruction(0x8000);await h.address(64);await h.instruction(0x4500)
    await h.instruction(0x8400);await h.instruction(0x4500);await h.sync()
    await h.execute(op=0);await h.store(0x1120,0);await h.inspect(0x1120,0x50004a00)
    # 508 advances to 512; the following access fails instead of wrapping.
    await h.instruction(0x9000);await h.address(508);await h.instruction(0x5500)
    await h.sync();assert not int(d.uo_out.value)&2
    await h.instruction(0x5500);await h.sync();assert int(d.uo_out.value)&2

@cocotb.test()
async def scalar_columns(d):
    h=Host(d);await h.reset()
    await h.load(0);await h.sync() # buffer [1,2], loaded only once
    async def weights(cur, address=4, sparse=False, increment=False):
        await h.instruction(0x8500|(cur<<9)|(int(sparse)<<11))
        await h.address(address);await h.instruction(0x4000|(int(increment)<<8));await h.sync()
    async def accumulate():
        await h.instruction(0x7800);await h.sync()
    await weights(0);await h.execute();await h.store(0x1200,0)
    await h.inspect(0x1200,0x44004200) # [3,4]
    # DATA selection alone changes cur; no input or weight reload is necessary.
    await h.instruction(0x8700);await accumulate();await h.store(0x1210,0)
    await h.inspect(0x1210,0x4a004880) # [9,12]
    await accumulate();await h.store(0x1220,0)
    await h.inspect(0x1220,0x4d004b80) # [15,20], cur still 1
    # Buffer [subnormal,0]: only selected element determines sparsity.
    await h.load(16);await h.sync();before=int(d.flash_read_ops.value)
    await weights(1,sparse=True,increment=True)
    assert int(d.flash_read_ops.value)==before
    await accumulate();await h.store(0x1230,0);await h.inspect(0x1230,0x4d004b80)
    # Select nonzero subnormal: all four weight bytes must now be read.
    before=int(d.flash_read_ops.value)
    await weights(0,sparse=True);assert int(d.flash_read_ops.value)==before+4
    await h.execute();await h.store(0x1240,0);await h.inspect(0x1240,0x04000300)
    # Both signs of zero skip and preserve the accumulator.
    await h.load(12);await h.sync()
    for cur in [0,1]:
        before=int(d.flash_read_ops.value);await weights(cur,sparse=True)
        assert int(d.flash_read_ops.value)==before
        await accumulate()
    await h.store(0x1250,0);await h.inspect(0x1250,0x04000300)
    # Reset restores vector mode, selector 0 and empty operand registers.
    await h.reset();await h.load(0);await h.load(4,weight=True);await h.sync()
    await h.execute();await h.store(0x1260,0);await h.inspect(0x1260,0x48004200)

@cocotb.test()
async def micro_columns(d):
    h=Host(d);await h.reset()
    # Initialize four output partial sums through the real instruction path.
    await h.load(12);await h.load(20,weight=True);await h.sync();await h.execute()
    await h.store(128);await h.store(132)
    async def configure(inp,weight,acc,groups,columns,input_sram=0,weight_sram=0):
        await h.address(inp);await h.instruction(0xa000|input_sram)
        await h.address(weight);await h.instruction(0xa400|weight_sram)
        await h.address(acc);await h.instruction(0xa800)
        await h.instruction(0xac00|groups);await h.instruction(0xb000|columns)
    await configure(0x200,0x300,128,2,5)
    before=int(d.flash_read_ops.value)
    await h.instruction(0xb401) # sparse RUN, owns cur and both loop counts
    # SYNC is queued during RUN and must not retire until every SRAM write completes.
    await h.sync()
    assert not int(d.uo_out.value)&2
    assert int(d.flash_read_ops.value)-before==12+24 # 3 input pairs + 3 nonzero columns
    await h.copy_sram_to_flash(128,0x1300);await h.inspect(0x1300,0x518050c0) # [38,44]
    await h.copy_sram_to_flash(132,0x1310);await h.inspect(0x1310,0x53005240) # [50,56]
    # Reconfigure and repeat: results add to existing SRAM partial sums.
    await configure(0x200,0x300,128,2,5);await h.instruction(0xb401);await h.sync()
    await h.copy_sram_to_flash(128,0x1320);await h.inspect(0x1320,0x558054c0) # [76,88]
    await h.copy_sram_to_flash(132,0x1330);await h.inspect(0x1330,0x57005640) # [100,112]
    # length=0 performs no accesses, even with otherwise unusable pointers.
    await configure(0xffffff,0xffffff,128,2,0)
    before=int(d.flash_read_ops.value);await h.instruction(0xb401);await h.sync()
    assert int(d.flash_read_ops.value)==before and not int(d.uo_out.value)&2
    # Output range rejected before any input/weight read or partial write.
    await configure(0x200,0x300,508,2,1)
    before=int(d.flash_read_ops.value);await h.instruction(0xb401);await h.sync()
    assert int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==before
    await h.reset()
    await h.copy_sram_to_flash(128,0x1340);await h.inspect(0x1340,0x558054c0)
    d._log.info('PASS fixed column sequencer, automatic cur, SRAM accumulation, sparse skip, zero length and bounds')

@cocotb.test()
async def micro_sram_and_faults(d):
    h=Host(d);await h.reset()
    async def config(inp,weight,inpdev=0,wdev=0):
        await h.address(inp);await h.instruction(0xa000|inpdev)
        await h.address(weight);await h.instruction(0xa400|wdev)
        await h.address(508);await h.instruction(0xa800)
        await h.instruction(0xac01);await h.instruction(0xb001)
    async def clear_output():
        await h.load(12);await h.load(20,weight=True);await h.sync()
        await h.execute();await h.store(508)
    # Initialize SRAM input/weight vectors using ordinary arithmetic and writes.
    for flash,local in [(0,0),(4,16)]:
        await h.load(flash);await h.load(20,weight=True);await h.sync()
        await h.execute();await h.store(local)
    await clear_output();await config(0,16,1,1)
    before=int(d.flash_read_ops.value)
    await h.instruction(0xb400);await h.sync()
    assert int(d.flash_read_ops.value)==before and not int(d.uo_out.value)&2
    await h.copy_sram_to_flash(508,0x1400);await h.inspect(0x1400,0x44004200)
    # Dense zero * NaN reads weights and propagates NaNs (not sparse suppression).
    await clear_output();await config(12,0x310)
    before=int(d.flash_read_ops.value);await h.instruction(0xb400);await h.sync()
    assert int(d.flash_read_ops.value)==before+8
    await h.copy_sram_to_flash(508,0x1410);await h.inspect(0x1410,0x7e007e00)
    # Invalid SRAM weight access aborts before a new output write; no hang at SYNC.
    await clear_output();await config(0,512,1,1)
    await h.instruction(0xb400);await h.sync();assert int(d.uo_out.value)&2
    await h.reset();await h.copy_sram_to_flash(508,0x1420)
    await h.inspect(0x1420,0x80000000)


@cocotb.test()
async def micro_batch_reuses_weights(d):
    import struct
    h=Host(d);await h.reset()
    # Three samples, three columns, four output lanes. Partial sums start at 1.
    # Two tile invocations test accumulation rather than implicit clearing.
    await h.load(20);await h.load(20,weight=True);await h.sync();await h.execute()
    for a in range(128,152,4):await h.store(a)
    # Put packed input pairs in SRAM; weights remain in Flash.
    await h.dma_copy(0x400,0,6)
    for iteration in (1,2):
        await h.address(0);await h.instruction(0xa001)
        await h.address(0x500);await h.instruction(0xa400)
        await h.address(128);await h.instruction(0xa800)
        await h.instruction(0xac02);await h.instruction(0xb003)
        await h.instruction(0xb803) # batch size 3
        before=int(d.flash_read_ops.value)
        await h.instruction(0xb401);await h.sync()
        assert not int(d.uo_out.value)&2
        # Each 4-byte weight vector read once, independent of batch size.
        assert int(d.flash_read_ops.value)-before==3*2*4
        for group in range(2):
            for batch,x in enumerate([[1,0,3],[2,4,0],[0,-2,1]]):
                ys=[1+iteration*sum(x[c]*(c*4+group*2+lane+1) for c in range(3)) for lane in range(2)]
                bits=int.from_bytes(struct.pack('<ee',*ys),'little')
                target=0x1800+(iteration-1)*0x100+group*32+batch*4
                await h.copy_sram_to_flash(128+4*(group*3+batch),target)
                await h.inspect(target,bits)


@cocotb.test()
async def dma_bit_exact_and_bounds(d):
    h=Host(d);await h.reset()
    pattern=bytearray(((i*37+11) ^ (i>>1))&255 for i in range(512))
    pattern[:12]=bytes.fromhex('00000080007c017d010000fc')
    # Real Flash -> DMA -> SRAM path; no arithmetic or SRAM backdoor preload.
    before=int(d.flash_read_ops.value)
    await h.dma_copy(0x800,0,128)
    assert int(d.flash_read_ops.value)-before==1 and not int(d.uo_out.value)&2
    assert int(d.uio_out.value)&1, "DMA completed with Flash still selected"
    async def raw(local,expected):
        d.observe_upper.value=bool(local&4)
        await h.load(local,1);await h.sync()
        assert int(d.mem_observe_data.value)==int.from_bytes(expected,'little')
    for off in range(0,512,4):await raw(off,pattern[off:off+4])
    # Unaligned Flash source, upper SRAM half; lower neighbor must survive RMW.
    await h.dma_copy(0x801,4,1)
    await raw(0,pattern[:4]);await raw(4,pattern[1:5]);await raw(8,pattern[8:12])
    # Operand registers stay intact across a copy; DMA must not deliver operands.
    await h.load(0);await h.load(4,weight=True);await h.sync()
    await h.dma_copy(0x800,508,1)
    await h.execute();await h.store(0x1c00,0);await h.inspect(0x1c00,0x48004200)
    # Empty DMA does no bus work. Invalid spans do not partially overwrite SRAM.
    before=int(d.flash_read_ops.value);await h.dma_copy(0x800,0,0)
    assert int(d.flash_read_ops.value)==before
    for source,dest,count in [(0x800,508,2),(0xfffffd,0,1),(0x800,2,1),(0x800,0,129)]:
        await h.reset();before=int(d.flash_read_ops.value)
        await h.dma_copy(source,dest,count)
        assert int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==before
        await h.reset();await raw(0,pattern[:4]);await raw(508,pattern[:4])


@cocotb.test()
async def dma_burst_weights_to_micro(d):
    h=Host(d);await h.reset()
    # Keep input, weight and output tiles separate in the existing 512 B SRAM.
    before=int(d.flash_read_ops.value)
    for source,dest,count in [(0x200,0,3),(0x300,16,10),(12,128,1),(12,132,1)]:
        await h.dma_copy(source,dest,count)
    assert int(d.flash_read_ops.value)-before==4
    await h.address(0);await h.instruction(0xa001)
    await h.address(16);await h.instruction(0xa401)
    await h.address(128);await h.instruction(0xa800)
    await h.instruction(0xac02);await h.instruction(0xb005)
    before=int(d.flash_read_ops.value)
    await h.instruction(0xb401);await h.sync()
    assert int(d.flash_read_ops.value)==before and not int(d.uo_out.value)&2
    for addr,expected in [(128,0x518050c0),(132,0x53005240)]:
        d.observe_upper.value=bool(addr&4)
        await h.load(addr,1);await h.sync()
        assert int(d.mem_observe_data.value)==expected


@cocotb.test()
async def dma_burst_reset(d):
    h=Host(d);await h.reset()
    await h.address(0x800);await h.instruction(0xc000)
    await h.address(0);await h.instruction(0xc400)
    before=int(d.flash_read_ops.value)
    await h.instruction(0xc880)
    for _ in range(1000):
        if int(d.flash_read_ops.value)>before:break
        await h.cycles()
    else:raise AssertionError('DMA never started its Flash burst')
    await h.cycles(200)
    assert not int(d.uio_out.value)&1, '512 B burst ended unexpectedly early'
    await h.reset()
    assert int(d.uio_out.value)&1 and not int(d.uio_out.value)&8
    assert not int(d.uo_out.value)&2
    # A fresh copy must start from its new address, not resume the aborted stream.
    before=int(d.flash_read_ops.value)
    await h.dma_copy(0x804,508,1)
    assert int(d.flash_read_ops.value)==before+1
    d.observe_upper.value=1
    await h.load(508,1);await h.sync()
    assert int(d.mem_observe_data.value)==0x7d017c00


@cocotb.test()
async def micro_auto_dma_tiles(d):
    """Generic GEMV: stride, output tiles, column tiles, sparse and dense modes."""
    import struct
    h=Host(d);await h.reset()
    await h.dma_copy(0x200,0,3) # [1,2,0,3,-0,padding]
    async def configure(inp,weight,acc,groups,columns,stride=0,inpdev=1):
        await h.address(inp);await h.instruction(0xa000|inpdev)
        await h.address(weight);await h.instruction(0xa400)
        await h.address(acc);await h.instruction(0xa800)
        await h.address(64);await h.instruction(0xbc00)
        await h.address(stride);await h.instruction(0xbc01)
        await h.instruction(0xac00|groups);await h.instruction(0xb000|columns)
    async def raw(addr,values):
        await h.load(addr,1);await h.sync()
        assert int(d.mem_observe_data.value)==int.from_bytes(struct.pack('<ee',*values),'little')
    # Four outputs with initial bias 1; three nonzero columns -> three bursts.
    for a in (128,132):await h.dma_copy(20,a,1)
    await configure(0,0x300,128,2,5)
    before=int(d.flash_read_ops.value)
    await h.instruction(0xb403);await h.sync()
    assert int(d.flash_read_ops.value)==before+3 and not int(d.uo_out.value)&2
    await raw(128,[39,45]);await raw(132,[51,57])
    # Independent two-output tiles from the same full matrix, column stride 8.
    # No repacking of Flash weights is needed to select the second output pair.
    for offset,expected in [(0,[38,44]),(4,[50,56])]:
        await h.dma_copy(12,128,1)
        await configure(0,0x300+offset,128,1,5,stride=8)
        before=int(d.flash_read_ops.value);await h.instruction(0xb403);await h.sync()
        assert int(d.flash_read_ops.value)==before+3 and not int(d.uo_out.value)&2
        await raw(128,expected)
    # Split the input dimension into two column tiles and retain partial sums.
    for a in (128,132):await h.dma_copy(12,a,1)
    for inp,weight,columns in [(0,0x300,2),(4,0x310,3)]:
        await configure(inp,weight,128,2,columns)
        await h.instruction(0xb403);await h.sync()
    await raw(128,[38,44]);await raw(132,[50,56])
    # Flash inputs are legal too; the weight DMA must not disturb input operands.
    for a in (128,132):await h.dma_copy(12,a,1)
    await configure(0x200,0x300,128,2,5,inpdev=0)
    before=int(d.flash_read_ops.value);await h.instruction(0xb403);await h.sync()
    assert int(d.flash_read_ops.value)==before+12+3
    await raw(128,[38,44]);await raw(132,[50,56])
    # Reuse the retained configuration after restoring consumed input/weight/count.
    await h.address(0);await h.instruction(0xa001)
    await h.address(0x300);await h.instruction(0xa400)
    await h.instruction(0xb005);await h.instruction(0xb403);await h.sync()
    await raw(128,[76,88]);await raw(132,[100,112])
    # Ordinary SRAM MICRO still works after the DMA mode; RUN bit 1 is not sticky.
    await h.dma_copy(0x300,64,2)
    await h.address(0);await h.instruction(0xa001)
    await h.address(64);await h.instruction(0xa401)
    await h.instruction(0xb001)
    before=int(d.flash_read_ops.value);await h.instruction(0xb401);await h.sync()
    assert int(d.flash_read_ops.value)==before and not int(d.uo_out.value)&2
    await raw(128,[77,90]);await raw(132,[103,116])
    # Dense mode intentionally loads NaN weights for a zero input.
    await h.dma_copy(12,0,1)
    await configure(0,0x310,128,1,1)
    before=int(d.flash_read_ops.value);await h.instruction(0xb402);await h.sync()
    assert int(d.flash_read_ops.value)==before+1
    await h.load(128,1);await h.sync()
    assert int(d.mem_observe_data.value)==0x7e007e00


@cocotb.test()
async def micro_auto_dma_faults_reset(d):
    h=Host(d);await h.reset()
    async def config(weight=0x800,groups=32,columns=2,buffer=64,acc=256,stride=0):
        await h.address(0);await h.instruction(0xa001)
        await h.address(weight);await h.instruction(0xa400)
        await h.address(buffer);await h.instruction(0xbc00)
        await h.address(acc);await h.instruction(0xa800)
        await h.address(stride);await h.instruction(0xbc01)
        await h.instruction(0xac00|groups);await h.instruction(0xb000|columns)
    # Overlap is rejected before any input read/DMA write. Existing SRAM survives.
    await h.dma_copy(0,0,1)
    await config(buffer=0)
    before=int(d.flash_read_ops.value);await h.instruction(0xb403);await h.sync()
    assert int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==before
    await h.reset();await h.load(0,1);await h.sync()
    assert int(d.mem_observe_data.value)==0x40003c00
    # DMA's complete span check rejects an invalid Flash range without bus work.
    await config(weight=0xfffffd,groups=1,columns=1)
    before=int(d.flash_read_ops.value);await h.instruction(0xb403);await h.sync()
    assert int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==before
    # Saturation on a large stride cannot wrap to valid Flash address zero.
    await h.reset();await h.dma_copy(12,256,1)
    await config(weight=0x300,groups=1,columns=2,stride=0xffff00)
    before=int(d.flash_read_ops.value);await h.instruction(0xb403);await h.sync()
    assert int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==before+1
    await h.reset();await h.load(256,1);await h.sync()
    assert int(d.mem_observe_data.value)==0x40003c00 # first column committed
    # An all-zero column does not DMA even with an unusable Flash address.
    await h.dma_copy(12,0,1);await config(weight=0xffffff,groups=1,columns=2)
    before=int(d.flash_read_ops.value);await h.instruction(0xb403);await h.sync()
    assert not int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==before
    # Reset while auto DMA holds CS; no stale run or byte stream may resume.
    await h.dma_copy(0,0,1);await config()
    before=int(d.flash_read_ops.value);await h.instruction(0xb403)
    for _ in range(2000):
        if int(d.flash_read_ops.value)>before:break
        await h.cycles()
    else:raise AssertionError('automatic DMA did not start')
    assert not int(d.uio_out.value)&1
    await h.reset();assert int(d.uio_out.value)&1 and not int(d.uo_out.value)&2
    await h.dma_copy(12,256,1);await config(weight=0x300,groups=1,columns=1)
    await h.instruction(0xb403);await h.sync()
    assert not int(d.uo_out.value)&2
    await h.load(256,1);await h.sync()
    assert int(d.mem_observe_data.value)==0x40003c00


@cocotb.test()
async def micro_auto_dma_batches(d):
    import struct
    h=Host(d);await h.reset()
    async def configure(inp,device,batches,columns=3,groups=2):
        await h.address(inp);await h.instruction(0xa000|device)
        await h.address(0x500);await h.instruction(0xa400)
        await h.address(64);await h.instruction(0xbc00)
        await h.address(128);await h.instruction(0xa800)
        await h.address(0);await h.instruction(0xbc01)
        await h.instruction(0xac00|groups);await h.instruction(0xb000|columns)
        await h.instruction(0xb800|batches)
    cases=[(3,0x400,[[1,0,3],[2,4,0],[0,-2,1]],3),
           (4,0x600,[[0,1,0],[0,0,2],[0,-2,0],[0,0,3]],2)]
    for batches,source,samples,bursts in cases:
        await h.dma_copy(source,0,2*batches)
        for g in range(2):
            for b in range(batches):await h.dma_copy(20,128+4*(g*batches+b),1)
        for iteration in (1,2):
            await configure(0,1,batches)
            before=int(d.flash_read_ops.value)
            await h.instruction(0xb403);await h.sync()
            assert int(d.flash_read_ops.value)==before+bursts and not int(d.uo_out.value)&2
            for g in range(2):
                for b,x in enumerate(samples):
                    expected=[1+iteration*sum(x[c]*(c*4+g*2+lane+1) for c in range(3)) for lane in range(2)]
                    await h.load(128+4*(g*batches+b),1);await h.sync()
                    assert int(d.mem_observe_data.value)==int.from_bytes(struct.pack('<ee',*expected),'little')
    # Flash-resident batch: zero-column prescan and later compute reread packed pairs.
    for addr in range(128,160,4):await h.dma_copy(12,addr,1)
    await configure(0x600,0,4)
    before=int(d.flash_read_ops.value);await h.instruction(0xb403);await h.sync()
    assert int(d.flash_read_ops.value)==before+94 and not int(d.uo_out.value)&2
    for g in range(2):
        for b,x in enumerate(cases[1][2]):
            expected=[sum(x[c]*(c*4+g*2+lane+1) for c in range(3)) for lane in range(2)]
            await h.load(128+4*(g*4+b),1);await h.sync()
            assert int(d.mem_observe_data.value)==int.from_bytes(struct.pack('<ee',*expected),'little')
    # Dense batch copies even the all-zero column; no stale sparse scan flag.
    await configure(0,1,4)
    before=int(d.flash_read_ops.value);await h.instruction(0xb402);await h.sync()
    assert int(d.flash_read_ops.value)==before+3 and not int(d.uo_out.value)&2
    for g in range(2):
        for b,x in enumerate(cases[1][2]):
            expected=[2*sum(x[c]*(c*4+g*2+lane+1) for c in range(3)) for lane in range(2)]
            await h.load(128+4*(g*4+b),1);await h.sync()
            assert int(d.mem_observe_data.value)==int.from_bytes(struct.pack('<ee',*expected),'little')
    # Switching to batch=1 after a batch reuses the same mode safely.
    await h.dma_copy(0,0,1);await h.dma_copy(12,128,1)
    await configure(0,1,1,columns=1,groups=1)
    await h.instruction(0xb403);await h.sync();await h.load(128,1);await h.sync()
    assert int(d.mem_observe_data.value)==0x40003c00
