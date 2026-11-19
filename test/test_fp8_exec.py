"""FP8 execution against the independent exact-rational reference."""
import random
import cocotb
from cocotb.triggers import Timer
from fp8_reference import encode8, add8 as add, mul8 as mul, sigmoid, tanh, F

def fp(v):return encode8(F(v))
def vector(a,b):return a | b<<8
def activate(a,op):
    if a&127==127:return 127
    if op==0:return a
    if op==1:return 0 if a&128 else a
    if op==2:return tanh(a)
    if op==3:return sigmoid(a)
    return 0x38 if not a&128 and a&127 else 0

@cocotb.test()
async def fp8_exec_vectors(d):
    async def tick():
        d.clk.value = 0
        await Timer(50, unit='ns')
        d.clk.value = 1
        await Timer(50, unit='ns')
    d.input_scalar_mode.value = 0
    d.input_select.value = 0
    d.input_sparse.value = 0
    d.rst_n.value = 0
    d.data_in_val.value = 0
    d.exec_inst_in_val.value = 0
    d.data_in.value = 0
    d.is_weight.value = 0
    d.exec_inst_in.value = 0
    for _ in range(3): await tick()
    d.rst_n.value = 1
    await tick()
    rng = random.Random(1802)
    edges=[0,0x80,1,7,8,0x38,0xb8,0x7e,0xfe,0x7f,0xff]
    cases = [(vector(fp(1),fp(-2)),vector(fp(3),fp(4)),op,act,False) for op in range(3) for act in range(5)]
    for _ in range(100):
        op = rng.randrange(3)
        cases.append((vector(rng.choice(edges),rng.randrange(256)),vector(rng.choice(edges),rng.randrange(256)),op,rng.randrange(5),op==2 and bool(rng.randrange(2))))
    acc = [0,0]
    for x,w,op,act,accum in cases:
        for weight,data in [(0,x),(1,w)]:
            d.is_weight.value=weight;d.data_in.value=data;d.data_in_val.value=1
            await tick()
        d.data_in_val.value=0
        assert int(d.exec_rdy.value)
        d.exec_inst_in.value=(int(accum)<<5)|(op<<3)|act
        d.exec_inst_in_val.value=1
        await tick()
        d.exec_inst_in_val.value=0
        for _ in range(100):
            await tick()
            if int(d.data_out_val.value): break
        else: raise AssertionError('EXEC did not complete')
        expected=[]
        for lane in range(2):
            a,b=(x>>(lane*8))&255,(w>>(lane*8))&255
            product=mul(a,b)
            raw=add(a,b) if op==0 else add(a,b^0x80) if op==1 else add(product,acc[lane]) if accum else product
            acc[lane]=raw;expected.append(activate(raw,act))
        assert int(d.data_out.value)==vector(*expected),(hex(x),hex(w),op,act)
        for _ in range(3):
            await tick()
            assert int(d.data_out.value)==vector(*expected)
    d._log.info('PASS 115 FP8 vector operations, stationary results and accumulator')

@cocotb.test()
async def scalar_selection_and_snapshot(d):
    async def tick():
        d.clk.value=0;await Timer(50,unit='ns')
        d.clk.value=1;await Timer(50,unit='ns')
    d.rst_n.value=0;d.data_in_val.value=0;d.exec_inst_in_val.value=0
    d.data_in.value=0;d.is_weight.value=0;d.exec_inst_in.value=0
    d.input_scalar_mode.value=0;d.input_select.value=0;d.input_sparse.value=0
    await tick();await tick();d.rst_n.value=1;await tick()
    rng=random.Random(512)
    edges=[0,0x80,1,7,8,0x38,0xb8,0x7e,0xfe,0x7f,0xff]
    acc=[0,0]
    for i in range(100):
        cur=i%2;op=i%3;act=i%5;sparse=bool(i%2);accum=bool(i%4)
        # Ensure both zero signs exercise sparse MUL accumulation.
        a=edges[(i//2)%len(edges)]
        x=vector(a,fp(2)) if cur==0 else vector(fp(-3),a)
        w=vector(rng.choice(edges),rng.choice(edges))
        for weight,data in [(0,x),(1,w)]:
            d.is_weight.value=weight;d.data_in.value=data;d.data_in_val.value=1;await tick()
        d.data_in_val.value=0
        d.input_scalar_mode.value=1;d.input_select.value=cur;d.input_sparse.value=sparse
        d.exec_inst_in.value=(int(accum)<<5)|(op<<3)|act;d.exec_inst_in_val.value=1
        await tick();d.exec_inst_in_val.value=0
        # Selection and operands may change while busy; accepted EXEC keeps its snapshot.
        d.input_select.value=1-cur;d.input_scalar_mode.value=0;d.input_sparse.value=not sparse
        d.data_in_val.value=1;d.is_weight.value=0;d.data_in.value=0x7f7f
        expected=[]
        for lane in range(2):
            b=(w>>(8*lane))&255
            if sparse and a&0x7f==0 and op==2:
                raw=acc[lane] if accum else 0
            elif op==0:raw=add(a,b)
            elif op==1:raw=add(a,b^0x80)
            else:
                product=mul(a,b);raw=add(product,acc[lane]) if accum else product
            acc[lane]=raw;expected.append(activate(raw,act))
        for _ in range(100):
            await tick();d.data_in_val.value=0
            if int(d.data_out_val.value):break
        else:raise AssertionError('Scalar EXEC timeout')
        assert int(d.data_out.value)==vector(*expected),(i,hex(a),hex(w),cur,op,act)
    d._log.info('PASS scalar broadcast, zero skip, activations and EXEC snapshots')

@cocotb.test()
async def fp8_activations_exhaustive(d):
    async def tick():
        d.clk.value=0;await Timer(5,unit='ns')
        d.clk.value=1;await Timer(5,unit='ns')
    d.rst_n.value=0;d.exec_inst_in_val.value=0;d.data_in_val.value=0
    d.input_scalar_mode.value=0;d.input_select.value=0;d.input_sparse.value=0
    d.data_in.value=0;d.is_weight.value=0;d.exec_inst_in.value=0
    await tick();d.rst_n.value=1;await tick()
    d.data_in.value=0x3838;d.is_weight.value=1;d.data_in_val.value=1;await tick()
    for act in range(5):
        for a in range(256):
            b=a^128;d.is_weight.value=0;d.data_in.value=vector(a,b);d.data_in_val.value=1
            await tick();d.data_in_val.value=0
            d.exec_inst_in.value=(2<<3)|act;d.exec_inst_in_val.value=1
            await tick();d.exec_inst_in_val.value=0
            for _ in range(10):
                await tick()
                if int(d.data_out_val.value):break
            else:raise AssertionError('activation timeout')
            assert int(d.data_out.value)==vector(activate(a,act),activate(b,act)),(hex(a),act)
