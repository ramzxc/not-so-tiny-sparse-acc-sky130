"""FP8 two-lane UART, burst DMA, full 1 KiB SRAM and generic MICRO integration."""
import os
import cocotb
from test_serial import Host
from fp8_reference import encode8, add8, mul8, F

def host(d):
    h=Host(d);h.period=int(os.environ.get('PERF_UART_CLKS_PER_BIT','8'));return h

def raw(d,address):
    return (int(d.perf_sram_snapshot.value)>>(address*8))&65535

async def config(h,inp,weight,acc,groups,columns,batch=1,buffer=512,stride=0,inpdev=1):
    for address,command in [(inp,0xa000|inpdev),(weight,0xa400),(acc,0xa800),
                            (buffer,0xbc00),(stride,0xbc01)]:
        await h.address(address);await h.instruction(command)
    for word in (0xac00|groups,0xb000|columns,0xb800|batch):await h.instruction(word)

@cocotb.test()
async def dma_full_1k_and_bounds(d):
    h=host(d);await h.reset()
    # Counts are 2-byte vectors, 1..255. Cover every byte, including 512 and 1023.
    before=int(d.flash_read_ops.value)
    for offset,count in [(0,255),(510,255),(1020,2)]:
        await h.dma_copy(0x800+offset,offset,count)
    assert int(d.flash_read_ops.value)-before==3
    snapshot=int(d.perf_sram_snapshot.value)
    for i in range(1024):assert (snapshot>>(8*i))&255==((i*37+11)^(i>>1))&255
    assert not int(d.uo_out.value)&2
    # A two-byte transfer must preserve the other three slots in the same row.
    for address in [0,2,4,6,510,512,514,1022]:
        await h.dma_copy(0,address,1)
        snapshot=(snapshot&~(65535<<(address*8)))|(0x4038<<(address*8))
        assert int(d.perf_sram_snapshot.value)==snapshot
    for source,destination,count in [(0,1,1),(0,1024,1),(0,1022,2),(0xffffff,0,1)]:
        await h.reset();before=int(d.flash_read_ops.value)
        await h.dma_copy(source,destination,count)
        assert int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==before
        assert int(d.perf_sram_snapshot.value)==snapshot
    await h.reset();before=int(d.flash_read_ops.value)
    await h.dma_copy(0xffffff,1022,0)
    assert not int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==before

@cocotb.test()
async def arithmetic_and_postincrement(d):
    h=host(d);await h.reset()
    await h.load(0);await h.load(4,weight=True);await h.sync();await h.execute()
    await h.store(1022);assert raw(d,1022)==(encode8(F(3))|(encode8(F(8))<<8))
    await h.address(510);await h.instruction(0x9000)
    for _ in range(3):await h.instruction(0x5500)
    await h.fence()
    assert raw(d,510)==raw(d,512)==raw(d,514)==raw(d,1022)
    await h.address(1022);await h.instruction(0x5500);await h.instruction(0x5500);await h.fence()
    assert int(d.uo_out.value)&2

@cocotb.test()
async def generic_tiles_and_batches(d):
    h=host(d)
    cases=[(1,0x200,[[1,2,0,3,0]],0x300),
           (3,0x400,[[1,0,3],[2,4,0],[0,-2,1]],0x500),
           (4,0x600,[[0,1,0],[0,0,2],[0,-2,0],[0,0,3]],0x500)]
    for batch,source,samples,weight in cases:
        for inpdev in (1,0):
            await h.reset();columns=len(samples[0]);groups=2
            await h.dma_copy(source,0,((columns+1)//2)*batch)
            await h.dma_copy(0x1000,768,groups*batch)
            for iteration in (1,2):
                await config(h,0 if inpdev else source,weight,768,groups,columns,batch,inpdev=inpdev)
                await h.instruction(0xb403);await h.fence()
                assert not int(d.uo_out.value)&2
                for g in range(groups):
                    for b,x in enumerate(samples):
                        expected=[]
                        for lane in range(2):
                            acc=0
                            for _ in range(iteration):
                                for c,value in enumerate(x):
                                    if value:
                                        acc=add8(acc,mul8(encode8(F(value)),encode8(F(c*4+g*2+lane+1))))
                            expected.append(acc)
                        assert raw(d,768+2*(g*batch+b))==expected[0]|(expected[1]<<8)
    # Output tiling with the original matrix stride, no weight repacking.
    for offset in (0,2):
        await h.reset();await h.dma_copy(0x200,0,3);await h.dma_copy(0x1000,1022,1)
        await config(h,0,0x300+offset,1022,1,5,stride=4)
        await h.instruction(0xb403);await h.fence()
        expected=[]
        for lane in range(2):
            acc=0
            for c,value in enumerate([1,2,0,3,0]):
                if value:acc=add8(acc,mul8(encode8(F(value)),encode8(F(c*4+offset+lane+1))))
            expected.append(acc)
        assert raw(d,1022)==expected[0]|(expected[1]<<8)
        assert not int(d.uo_out.value)&2

@cocotb.test()
async def sparse_dense_and_fault_reset(d):
    h=host(d);await h.reset();await h.dma_copy(8,0,1)
    await h.dma_copy(0x1000,768,1)
    await config(h,0,0x308,768,1,1)
    before=int(d.flash_read_ops.value);await h.instruction(0xb403);await h.fence()
    assert raw(d,768)==0 and int(d.flash_read_ops.value)==before
    await config(h,0,0x308,768,1,1)
    await h.instruction(0xb402);await h.fence();assert raw(d,768)==0x7f7f
    # Overlap and upper bounds are rejected before any read/write.
    for inp,buffer,acc in [(0,0,768),(0,512,512),(1022,512,768),(1,512,768),(0,1022,768)]:
        await h.reset();await config(h,inp,0x500,acc,2,3,buffer=buffer)
        before=int(d.flash_read_ops.value);await h.instruction(0xb403);await h.fence()
        assert int(d.uo_out.value)&2 and int(d.flash_read_ops.value)==before
    # Reset an accepted long burst and return to ordinary SRAM MICRO afterwards.
    await h.reset();await h.dma_copy(0,0,1)
    await config(h,0,0x800,512,128,1,buffer=128)
    before=int(d.flash_read_ops.value);await h.instruction(0xb403)
    for _ in range(2000):
        if int(d.flash_read_ops.value)>before:break
        await h.cycles()
    else:raise AssertionError('DMA did not start')
    await h.reset();assert int(d.uio_out.value)&1 and not int(d.uo_out.value)&2
    await h.dma_copy(0,0,1);await h.dma_copy(4,512,1);await h.dma_copy(0x1000,1022,1)
    for addr,word in [(0,0xa001),(512,0xa401),(1022,0xa800)]:
        await h.address(addr);await h.instruction(word)
    for word in (0xac01,0xb001,0xb401):await h.instruction(word)
    await h.fence();assert raw(d,1022)==0x4844 and not int(d.uo_out.value)&2
