"""FP16/16-bit-ISA integration with the actual generated OpenRAM timing model."""
import math
import random
import struct

import cocotb
from cocotb.triggers import Timer


def fp(value):
    try:
        return int.from_bytes(struct.pack('<e', value), 'little')
    except OverflowError:
        return 0xfc00 if value < 0 else 0x7c00


def value(bits):
    return struct.unpack('<e', bits.to_bytes(2, 'little'))[0]


def add(a, b):
    x = value(a) + value(b)
    return 0x7e00 if math.isnan(x) else 0 if x == 0 else fp(x)


def mul(a, b):
    x = value(a) * value(b)
    return 0x7e00 if math.isnan(x) else fp(x)


def scale(a, power):
    x = value(a) * 2.0 ** power
    return 0x7e00 if math.isnan(x) else fp(x)


def sigmoid(a):
    if math.isnan(value(a)):return 0x7e00
    y=add(scale(a,-2),0x3800)
    return 0 if y&0x8000 else 0x3c00 if (y&0x7fff)>0x3c00 else y


def activate(a, op):
    if math.isnan(value(a)):return 0x7e00
    if op == 0:return a
    if op == 1:return 0 if a&0x8000 else a
    if op == 2:return (a&0x8000)|0x3c00 if (a&0x7fff)>0x3c00 else a
    if op == 3:return sigmoid(a)
    return 0x3c00 if not (a&0x8000) and (a&0x7fff)!=0 else 0


def vector(a, b):
    return a | b << 16


@cocotb.test()
async def fp16_exec_vectors(d):
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
    edges = [0,0x8000,1,0x0100,0x03ff,0x0400,0x3555,0x3c00,0xbc00,0x4500,0xc500,0x7bff,0x7c00,0xfc00,0x7e00]
    cases = [(vector(fp(1),fp(-2)),vector(fp(3),fp(4)),op,act,False) for op in range(3) for act in range(5)]
    for _ in range(100):
        op = rng.randrange(3)
        cases.append((vector(rng.choice(edges),rng.randrange(65536)),vector(rng.choice(edges),rng.randrange(65536)),op,rng.randrange(5),op==2 and bool(rng.randrange(2))))
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
            a,b=(x>>(lane*16))&65535,(w>>(lane*16))&65535
            product=mul(a,b)
            raw=add(a,b) if op==0 else add(a,b^0x8000) if op==1 else add(product,acc[lane]) if accum else product
            acc[lane]=raw;expected.append(activate(raw,act))
        assert int(d.data_out.value)==vector(*expected),(hex(x),hex(w),op,act)
        for _ in range(3):
            await tick()
            assert int(d.data_out.value)==vector(*expected)
    d._log.info('PASS 115 FP16 vector operations, stationary results and accumulator')

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
    edges=[0,0x8000,1,0x0100,0x3c00,0xbc00,0x7c00,0x7e00]
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
        d.data_in_val.value=1;d.is_weight.value=0;d.data_in.value=0x7e007e00
        expected=[]
        for lane in range(2):
            b=(w>>(16*lane))&65535
            if sparse and a&0x7fff==0 and op==2:
                raw=acc[lane] if accum else 0
            elif op==0:raw=add(a,b)
            elif op==1:raw=add(a,b^0x8000)
            else:
                product=mul(a,b);raw=add(product,acc[lane]) if accum else product
            acc[lane]=raw;expected.append(activate(raw,act))
        for _ in range(100):
            await tick();d.data_in_val.value=0
            if int(d.data_out_val.value):break
        else:raise AssertionError('Scalar EXEC timeout')
        assert int(d.data_out.value)==vector(*expected),(i,hex(a),hex(w),cur,op,act)
    d._log.info('PASS scalar broadcast, zero skip, activations and EXEC snapshots')
