"""Check emitted instructions independently under randomized downstream stalls."""
import random
import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def sequencer(d):
    rng=random.Random(513)
    async def settle():await Timer(1,unit='ns')
    async def tick():
        d.clk.value=0;await Timer(5,unit='ns')
        d.clk.value=1;await Timer(5,unit='ns')
    async def reset():
        d.rst_n.value=0;d.host_valid.value=0;d.host_inst.value=0
        d.core_ready.value=1;d.units_idle.value=1;d.staging_addr.value=0
        d.input_zero_mask.value=0;d.memory_error.value=0
        await tick();await tick();d.rst_n.value=1;await settle()
    async def cfg(word,addr=0):
        d.staging_addr.value=addr;d.host_inst.value=word;d.host_valid.value=1
        await settle();assert int(d.host_ready.value) and not int(d.core_valid.value)
        await tick();d.host_valid.value=0;await settle()
    def expected(groups,columns,masks,weight_sram=0):
        out=[];inp=0x200;weight=0xffc
        for col in range(columns):
            cur=col%2
            if not cur:
                out.extend([(0x8000,None),(0x2000|(inp&4095),None),(0x3000|(inp>>12),None),
                            (0x4000,None),(0xffff,masks[col//2])]);inp+=2
            if not (masks[col//2]>>cur)&1:
                for group in range(groups):
                    out.extend([(0x8d00|(cur<<9),None),(0x2000|(weight&4095),None),
                                (0x3000|(weight>>12),None),(0x4000|(weight_sram<<10),None),
                                (0xffff,None),(0x6800,None),(0xffff,None),(0x9000,None),
                                (0x2000|group*2,None),(0x3000,None),(0x5600,None),(0xffff,None)])
                    weight+=2
            else:weight+=groups*2
        return out
    async def run_case(groups,columns,masks):
        await reset()
        await cfg(0xa000,0x200);await cfg(0xa400,0xffc);await cfg(0xa800,0)
        await cfg(0xac00|groups);await cfg(0xb000|columns);await cfg(0xb401)
        want=expected(groups,columns,masks) if groups and columns else [];index=0;held=None
        d.host_inst.value=0x6800;d.host_valid.value=1 # queued host operation
        for _ in range(20000):
            if not int(d.busy.value):break
            d.core_ready.value=rng.randrange(4)!=0;await settle()
            assert not int(d.host_ready.value)
            valid=int(d.core_valid.value);word=int(d.core_inst.value)
            if held is not None:assert valid and word==held,'instruction changed under backpressure'
            accepted=valid and int(d.core_ready.value)
            held=word if valid and not accepted else None
            mask=None
            if accepted:
                assert index<len(want) and word==want[index][0],(index,hex(word),want[index:index+1])
                mask=want[index][1];index+=1
            await tick()
            if mask is not None:d.input_zero_mask.value=mask
        else:raise AssertionError('sequencer stuck')
        assert index==len(want) and not int(d.error.value)
        # Passthrough resumes after the final sync; no host instruction was lost.
        d.core_ready.value=1;await settle()
        assert int(d.core_valid.value) and int(d.core_inst.value)==0x6800 and int(d.host_ready.value)
        d.host_valid.value=0
    await run_case(3,5,[2,1,0]) # selected zero skips, odd final column, address carry
    await run_case(255,1,[0]) # 510 B of output, maximum encoded group count
    await run_case(1,255,[3]*128) # full 8-bit column count, both zero signs represented by mask
    await run_case(0,5,[0]*3)
    await run_case(2,0,[])
    # Invalid configuration does not launch or emit an instruction.
    await reset();await cfg(0xa800,1022);await cfg(0xac02);await cfg(0xb001);await cfg(0xb400)
    assert int(d.error.value) and not int(d.busy.value)
    # Fault drains an accepted operation before returning host ownership.
    await reset();await cfg(0xac01);await cfg(0xb001);await cfg(0xb400)
    d.memory_error.value=1;d.units_idle.value=0
    for _ in range(3):
        await tick();assert int(d.busy.value) and not int(d.core_valid.value) and not int(d.host_ready.value)
    d.units_idle.value=1;await tick();assert not int(d.busy.value) and int(d.error.value)
    # Reset cancels a stalled sequencer and clears its status.
    await reset();await cfg(0xac01);await cfg(0xb001);await cfg(0xb400)
    d.core_ready.value=0;await tick();assert int(d.busy.value)
    await reset();assert not int(d.busy.value) and not int(d.error.value)


@cocotb.test()
async def batch_schedule(d):
    rng=random.Random(412)
    async def tick():
        d.clk.value=0;await Timer(5,unit='ns')
        d.clk.value=1;await Timer(5,unit='ns')
    async def reset():
        d.rst_n.value=0;d.host_valid.value=0;d.host_inst.value=0
        d.core_ready.value=1;d.units_idle.value=1;d.staging_addr.value=0
        d.input_zero_mask.value=0;d.memory_error.value=0
        await tick();d.rst_n.value=1;await Timer(1,unit='ns')
    async def cfg(word,addr=0):
        d.staging_addr.value=addr;d.host_inst.value=word;d.host_valid.value=1
        await tick();d.host_valid.value=0
    for batches,groups,columns in [(2,3,5),(3,2,3),(128,1,1),(2,64,1)]:
        await reset()
        await cfg(0xa000,0xffc);await cfg(0xa400,0x2000)
        await cfg(0xac00|groups);await cfg(0xb000|columns)
        await cfg(0xb800|batches);await cfg(0xb401)
        want=[]
        def emit(*words):want.extend((w,None) for w in words)
        for c in range(columns):
            for g in range(groups):
                w=0x2000+2*(c*groups+g)
                emit(0x8400,0x2000|(w&4095),0x3000|(w>>12),0x4000,0xffff)
                for b in range(batches):
                    a=0xffc+2*((c//2)*batches+b)
                    mask=rng.randrange(4)
                    emit(0x8900|((c%2)<<9),0x2000|(a&4095),0x3000|(a>>12),0x4000)
                    want.append((0xffff,mask))
                    if not (mask>>(c%2))&1:
                        emit(0x6800,0xffff,0x9000,0x2000|2*(g*batches+b),0x3000,0x5600)
                    emit(0xffff)
        index=0;held=None
        for _ in range(100000):
            if not int(d.busy.value):break
            d.core_ready.value=rng.randrange(3)!=0;await Timer(1,unit='ns')
            valid=int(d.core_valid.value);word=int(d.core_inst.value)
            if held is not None:assert valid and word==held
            accepted=valid and int(d.core_ready.value)
            held=word if valid and not accepted else None
            mask=None
            if accepted:
                assert index<len(want) and word==want[index][0],(index,hex(word),want[index:index+1])
                mask=want[index][1];index+=1
            await tick()
            if mask is not None:d.input_zero_mask.value=mask
        else:raise AssertionError('batch sequencer stuck')
        assert index==len(want) and not int(d.error.value)
    # Reject invalid sizes and SRAM overflow before issuing any operation.
    for size,groups,base in [(0,1,0),(129,1,0),(3,171,0),(3,1,1020)]:
        await reset();await cfg(0xb800|size);await cfg(0xac00|groups)
        await cfg(0xa800,base);await cfg(0xb001);await cfg(0xb400)
        for _ in range(300):
            assert not int(d.core_valid.value)
            await tick()
            if not int(d.busy.value):break
        assert int(d.error.value) and not int(d.busy.value)


@cocotb.test()
async def dma_tile_sequence(d):
    """Generic strided GEMV tiles: exact emitted commands under backpressure."""
    rng=random.Random(702)
    async def tick():
        d.clk.value=0;await Timer(5,unit='ns')
        d.clk.value=1;await Timer(5,unit='ns')
    async def settle():await Timer(1,unit='ns')
    async def reset():
        d.rst_n.value=0;d.host_valid.value=0;d.host_inst.value=0
        d.core_ready.value=1;d.units_idle.value=1;d.staging_addr.value=0
        d.input_zero_mask.value=0;d.memory_error.value=0
        await tick();d.rst_n.value=1;await settle()
    async def cfg(word,addr=0):
        d.host_inst.value=word;d.staging_addr.value=addr;d.host_valid.value=1
        await settle();assert int(d.host_ready.value)
        await tick();d.host_valid.value=0;await settle()
    for groups,columns,inp,inp_sram,buf,acc,stride,masks,sparse in [
        (2,5,0,1,64,128,0,[2,1,3],True),
        (32,3,0,1,64,256,512,[0,2],True),
        (255,1,0x200,0,0,514,0,[0],False),
        (1,5,0,1,64,128,0x1003,[3,3,0],True),
        (2,3,0,1,64,128,3,[3,3],False),
    ]:
        await reset()
        source=0xffd
        await cfg(0xa000|inp_sram,inp);await cfg(0xa400,source)
        await cfg(0xa800,acc);await cfg(0xbc00,buf);await cfg(0xbc01,stride)
        await cfg(0xac00|groups);await cfg(0xb000|columns);await cfg(0xb402|int(sparse))
        want=[]
        def emit(*words):want.extend((word,None) for word in words)
        def address(addr):emit(0x2000|(addr&4095),0x3000|(addr>>12))
        for col in range(columns):
            cur=col%2
            if not cur:
                emit(0x8000);address(inp+2*(col//2));emit(0x4000|(inp_sram<<10))
                want.append((0xffff,masks[col//2]))
            if not sparse or not (masks[col//2]>>cur)&1:
                address(source);emit(0xc000);address(buf);emit(0xc400,0xc800|groups,0xffff)
                for group in range(groups):
                    emit(0x8500|(int(sparse)<<11)|(cur<<9))
                    address(buf+2*group);emit(0x4400,0xffff,0x6800,0xffff,0x9000)
                    address(acc+2*group);emit(0x5600,0xffff)
            source=min(0xffffff,source+(stride or groups*2))
        # A queued host command must stay blocked for the entire tile.
        d.host_inst.value=0x6800;d.host_valid.value=1
        index=0;held=None;dma_stall=0
        for _ in range(30000):
            if not int(d.busy.value):break
            assert not int(d.host_ready.value)
            d.core_ready.value=0 if dma_stall else rng.randrange(4)!=0
            await settle()
            valid=int(d.core_valid.value);word=int(d.core_inst.value)
            if held is not None:assert valid and word==held
            accepted=valid and int(d.core_ready.value)
            held=word if valid and not accepted else None
            mask=None
            if accepted:
                assert index<len(want) and word==want[index][0],(index,hex(word),want[index:index+1])
                mask=want[index][1];index+=1
                if word&0xff00==0xc800:dma_stall=40
            elif dma_stall:dma_stall-=1
            await tick()
            if mask is not None:d.input_zero_mask.value=mask
        else:raise AssertionError('DMA tile stuck')
        assert index==len(want) and not int(d.error.value)
        d.core_ready.value=1;await settle();assert int(d.host_ready.value)
    # Bad SRAM layouts / source selection / batch mode fail before any command.
    for inp,buf,acc,groups,columns,batch,wdev in [
        (0,64,64,2,5,1,0), (0,4,128,2,5,1,0),
        (0,64,4,2,5,1,0), (0,1022,128,2,5,1,0),
        (1022,64,128,2,3,1,0), (1,64,128,2,5,1,0),
        (1024,64,128,2,5,1,0), (0,64,128,2,5,128,0),
        (0,64,128,2,5,1,1), (0,64,1022,2,5,1,0),
    ]:
        await reset();await cfg(0xa001,inp);await cfg(0xa400|wdev,0x2000)
        await cfg(0xbc00,buf);await cfg(0xa800,acc)
        await cfg(0xac00|groups);await cfg(0xb000|columns);await cfg(0xb800|batch)
        await cfg(0xb403)
        for _ in range(600):
            assert not int(d.core_valid.value)
            if not int(d.busy.value):break
            await tick()
        assert int(d.error.value) and not int(d.busy.value) and not int(d.core_valid.value)
    for word,addr in [(0xbc00,1),(0xbc00,1024),(0xbc02,0),(0xbc03,0),(0xb404,0)]:
        await reset();await cfg(word,addr)
        assert int(d.error.value) and not int(d.busy.value)
    # Zero columns is a no-op even if the unused tile layout overlaps.
    await reset();await cfg(0xac02);await cfg(0xb403)
    assert not int(d.busy.value) and not int(d.error.value)
    # DMA failure: stop dispatch immediately and drain until units_idle.
    await reset();await cfg(0xa000,0x200);await cfg(0xa400,0xfffffc)
    await cfg(0xbc00,0);await cfg(0xa800,128);await cfg(0xac02);await cfg(0xb001)
    await cfg(0xb403)
    for _ in range(100):
        if int(d.core_valid.value) and int(d.core_inst.value)==0xc802:break
        await tick()
    else:raise AssertionError('No DMA RUN')
    await tick();d.units_idle.value=0;d.memory_error.value=1;await settle()
    for _ in range(5):
        assert not int(d.core_valid.value);await tick();assert int(d.busy.value)
    d.units_idle.value=1;await tick()
    assert int(d.error.value) and not int(d.busy.value)
    await reset();assert not int(d.error.value)


@cocotb.test()
async def dma_batch_sequence(d):
    """One DMA per active column, batch reuse, and all-zero column suppression."""
    rng=random.Random(703)
    async def tick():
        d.clk.value=0;await Timer(5,unit='ns')
        d.clk.value=1;await Timer(5,unit='ns')
    async def settle():await Timer(1,unit='ns')
    async def reset():
        d.rst_n.value=0;d.host_inst.value=0;d.host_valid.value=0
        d.core_ready.value=1;d.units_idle.value=1;d.memory_error.value=0
        d.staging_addr.value=0;d.input_zero_mask.value=0
        await tick();d.rst_n.value=1;await settle()
    async def cfg(word,addr=0):
        d.host_inst.value=word;d.staging_addr.value=addr;d.host_valid.value=1
        await tick();d.host_valid.value=0;await settle()
    for batches,groups,columns,inp,inpdev,buf,acc,sparse in [
        (2,3,5,0,1,64,128,True), (3,2,3,0,1,64,128,True),
        (7,4,9,0,1,192,256,True), (63,1,1,0,1,252,256,True),
        (127,1,1,0x200,0,0,4,True), (128,1,1,0,1,512,768,True), (3,2,3,0,1,64,128,False),
    ]:
        masks=[[rng.randrange(4) for _ in range(batches)] for _ in range((columns+1)//2)]
        # Entire column 0 is zero; column 1 becomes nonzero only in the last sample.
        masks[0]=[3]*batches
        if columns>1:masks[0][-1]=1
        await reset();await cfg(0xa000|inpdev,inp);await cfg(0xa400,0xffd)
        await cfg(0xa800,acc);await cfg(0xbc00,buf);await cfg(0xbc01,0x104)
        await cfg(0xac00|groups);await cfg(0xb000|columns);await cfg(0xb800|batches)
        await cfg(0xb402|int(sparse))
        want=[]
        def emit(*words):want.extend((w,None) for w in words)
        def addr(a):emit(0x2000|(a&4095),0x3000|(a>>12))
        def read_input(c,b):
            emit(0x8100|(int(sparse)<<11)|((c%2)<<9))
            addr(inp+2*((c//2)*batches+b));emit(0x4000|(inpdev<<10))
            want.append((0xffff,masks[c//2][b]))
        for c in range(columns):
            active=False
            for b in range(batches):
                read_input(c,b)
                if not sparse or not (masks[c//2][b]>>(c%2))&1:
                    active=True;break
            if not active:continue
            addr(0xffd+c*0x104);emit(0xc000);addr(buf);emit(0xc400,0xc800|groups,0xffff)
            for g in range(groups):
                emit(0x8400);addr(buf+g*2);emit(0x4400,0xffff)
                for b in range(batches):
                    read_input(c,b)
                    if not sparse or not (masks[c//2][b]>>(c%2))&1:
                        emit(0x6800,0xffff,0x9000);addr(acc+2*(g*batches+b));emit(0x5600)
                    emit(0xffff)
        index=0;held=None;stall=0
        for _ in range(100000):
            if not int(d.busy.value):break
            d.core_ready.value=0 if stall else rng.randrange(4)!=0
            await settle();valid=int(d.core_valid.value);word=int(d.core_inst.value)
            if held is not None:assert valid and word==held
            accepted=valid and int(d.core_ready.value)
            held=word if valid and not accepted else None;mask=None
            if accepted:
                assert index<len(want) and word==want[index][0],(batches,index,hex(word),want[index:index+1])
                mask=want[index][1];index+=1
                if word&0xff00==0xc800:stall=100
            elif stall:stall-=1
            await tick()
            if mask is not None:d.input_zero_mask.value=mask
        else:raise AssertionError('batched DMA stuck')
        assert index==len(want) and not int(d.error.value)
    # Validate complete batch spans, including collisions beyond the first sample.
    for batches,columns,buf,acc,groups in [(4,5,20,128,2),(4,3,140,128,2),
                                         (64,1,256,920,1),(128,1,0,4,1)]:
        await reset();await cfg(0xa001,0);await cfg(0xa400,0x1000)
        await cfg(0xbc00,buf);await cfg(0xa800,acc);await cfg(0xac00|groups)
        await cfg(0xb000|columns);await cfg(0xb800|batches);await cfg(0xb403)
        for _ in range(600):
            assert not int(d.core_valid.value)
            if not int(d.busy.value):break
            await tick()
        assert not int(d.busy.value) and int(d.error.value)
