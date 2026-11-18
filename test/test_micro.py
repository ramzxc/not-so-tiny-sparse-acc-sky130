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
                            (0x4000,None),(0xffff,masks[col//2])]);inp+=4
            if not (masks[col//2]>>cur)&1:
                for group in range(groups):
                    out.extend([(0x8d00|(cur<<9),None),(0x2000|(weight&4095),None),
                                (0x3000|(weight>>12),None),(0x4000|(weight_sram<<10),None),
                                (0xffff,None),(0x6800,None),(0xffff,None),(0x9000,None),
                                (0x2000|group*4,None),(0x3000,None),(0x5600,None),(0xffff,None)])
                    weight+=4
            else:weight+=groups*4
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
    await run_case(128,1,[0]) # all 512 B of output, maximum legal group count
    await run_case(1,255,[3]*128) # full 8-bit column count, both zero signs represented by mask
    await run_case(0,5,[0]*3)
    await run_case(2,0,[])
    # Invalid configuration does not launch or emit an instruction.
    await reset();await cfg(0xa800,508);await cfg(0xac02);await cfg(0xb001);await cfg(0xb400)
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
                w=0x2000+4*(c*groups+g)
                emit(0x8400,0x2000|(w&4095),0x3000|(w>>12),0x4000,0xffff)
                for b in range(batches):
                    a=0xffc+4*((c//2)*batches+b)
                    mask=rng.randrange(4)
                    emit(0x8900|((c%2)<<9),0x2000|(a&4095),0x3000|(a>>12),0x4000)
                    want.append((0xffff,mask))
                    if not (mask>>(c%2))&1:
                        emit(0x6800,0xffff,0x9000,0x2000|4*(g*batches+b),0x3000,0x5600)
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
    for size,groups,base in [(0,1,0),(129,1,0),(2,65,0),(3,1,504)]:
        await reset();await cfg(0xb800|size);await cfg(0xac00|groups)
        await cfg(0xa800,base);await cfg(0xb001);await cfg(0xb400)
        for _ in range(300):
            assert not int(d.core_valid.value)
            await tick()
            if not int(d.busy.value):break
        assert int(d.error.value) and not int(d.busy.value)
