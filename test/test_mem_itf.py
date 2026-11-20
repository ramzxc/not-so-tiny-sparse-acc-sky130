"""All 1 KiB SRAM bytes, four vector slots per row, FP8 RMW and rejection."""
import random
import cocotb
from cocotb.triggers import Timer
from test_fp8_exec import add, vector, fp

@cocotb.test()
async def local_sram(d):
    async def tick():
        d.clk.value=0;await Timer(50,unit='ns')
        d.clk.value=1;await Timer(50,unit='ns')
    async def reset():
        d.rst_n.value=0;d.read_en.value=0;d.write_en.value=0;d.write_accumulate.value=0
        d.addr.value=0;d.device.value=1;d.write_data.value=0
        d.copy_en.value=0;d.copy_source.value=0;d.copy_destination.value=0;d.copy_vectors.value=0
        d.qspi_req_rdy.value=0;d.qspi_read_data.value=0;d.qspi_byte_valid.value=0;d.qspi_done.value=0
        for _ in range(3):await tick()
        d.rst_n.value=1;await tick()
    async def request(addr,data=None,acc=False,device=1):
        assert int(d.rdy.value)
        d.addr.value=addr;d.device.value=device;d.write_data.value=data or 0
        d.read_en.value=data is None;d.write_en.value=data is not None;d.write_accumulate.value=acc
        await tick();d.read_en.value=0;d.write_en.value=0;d.write_accumulate.value=0
        for _ in range(20):
            assert not int(d.qspi_req_val.value),'Local/invalid request escaped to PSRAM'
            if data is None and int(d.read_data_val.value):return int(d.read_data.value)
            if data is not None and int(d.rdy.value):return
            await tick()
        raise AssertionError('memory timeout')
    await reset();rng=random.Random(71);expected=[rng.getrandbits(16) for _ in range(512)]
    for i,data in enumerate(expected):await request(i*2,data)
    for i,data in enumerate(expected):assert await request(i*2)==data
    for i in [0,1,2,3,254,255,256,257,510,511]:
        a=vector(fp(1.5),fp(-2));b=vector(fp(2),fp(.5))
        await request(i*2,a);await request(i*2,b,True)
        expected[i]=vector(add(a&255,b&255),add(a>>8,b>>8))
        for j in range((i//4)*4,(i//4)*4+4):assert await request(j*2)==expected[j]
    snapshot=await request(0)
    for addr,dev in [(1,1),(1023,1),(1024,1),(0xffffff,1),(0,2),(0,3)]:
        await reset();assert await request(addr,device=dev)==0
        assert int(d.error.value)
        await request(addr,0xdead,device=dev)
        assert await request(0)==snapshot
    await reset();assert await request(0xffffff,device=0)==0;assert int(d.error.value)
    await reset();d.addr.value=0;d.write_data.value=0xdead;d.write_en.value=1
    await tick();await reset();assert await request(0)==snapshot

@cocotb.test()
async def row_copy_preserves_neighbors(d):
    rng=random.Random(92)
    async def tick():
        d.clk.value=0;await Timer(50,unit='ns');d.clk.value=1;await Timer(50,unit='ns')
    d.rst_n.value=0
    for n in ('read_en','write_en','write_accumulate','copy_en','copy_source','copy_destination','copy_vectors','qspi_req_rdy','qspi_read_data','qspi_byte_valid','qspi_done','addr','device','write_data'):getattr(d,n).value=0
    await tick();d.rst_n.value=1;await tick()
    async def vector(a,value=None):
        assert int(d.rdy.value)
        d.addr.value=a;d.device.value=1;d.write_data.value=value or 0
        d.read_en.value=value is None;d.write_en.value=value is not None
        await tick();d.read_en.value=0;d.write_en.value=0
        for _ in range(20):
            if value is None and int(d.read_data_val.value):
                answer=int(d.read_data.value);await tick();return answer
            if value is not None and int(d.rdy.value):return
            await tick()
        raise AssertionError('ordinary transaction timeout')
    for row in (0,64,1016):
        for slot in range(4):
            for count in range(1,5-slot):
                expected=bytearray(rng.getrandbits(8) for _ in range(8))
                for i in range(0,8,2):await vector(row+i,int.from_bytes(expected[i:i+2],'little'))
                src=0x7ffff8 if slot==0 and count==4 else 1021
                payload=bytes(rng.getrandbits(8) for _ in range(count*2))
                d.copy_source.value=src;d.copy_destination.value=row+slot*2;d.copy_vectors.value=count;d.copy_en.value=1
                await tick();d.copy_en.value=0
                for _ in range(10):
                    if int(d.qspi_req_val.value):break
                    await tick()
                else:raise AssertionError('copy did not request QPI')
                assert int(d.qspi_req_addr.value)==src and int(d.qspi_req_bytes.value)==2*count
                assert not int(d.qspi_req_write.value)
                for _ in range(3):await tick();assert not int(d.copy_done.value)
                d.qspi_req_rdy.value=1;await tick();d.qspi_req_rdy.value=0
                for b in payload:
                    for _ in range(rng.randrange(1,4)):await tick();assert not int(d.copy_done.value)
                    d.qspi_read_data.value=b;d.qspi_byte_valid.value=1;await tick();d.qspi_byte_valid.value=0
                d.qspi_done.value=1;await tick();d.qspi_done.value=0
                assert not int(d.copy_done.value),'must wait for SRAM commit'
                for _ in range(8):
                    if int(d.copy_done.value):break
                    await tick()
                else:raise AssertionError('copy did not commit')
                assert not int(d.error.value)
                await tick();expected[slot*2:(slot+count)*2]=payload
                for i in range(0,8,2):assert await vector(row+i)==int.from_bytes(expected[i:i+2],'little')

    # Reset during an unfinished full-row receive must not commit the row buffer.
    snapshot=[await vector(1016+i*2) for i in range(4)]
    d.copy_source.value=0;d.copy_destination.value=1016;d.copy_vectors.value=4;d.copy_en.value=1
    await tick();d.copy_en.value=0
    assert int(d.qspi_req_val.value)
    d.qspi_req_rdy.value=1;await tick();d.qspi_req_rdy.value=0
    for b in (1,2,3):
        d.qspi_read_data.value=b;d.qspi_byte_valid.value=1;await tick()
    d.qspi_byte_valid.value=0;d.rst_n.value=0;await tick();d.rst_n.value=1;await tick()
    assert not int(d.copy_done.value) and not int(d.error.value)
    for i,value in enumerate(snapshot):assert await vector(1016+i*2)==value
    # Bad row span is rejected before QPI or SRAM writes.
    d.copy_destination.value=1022;d.copy_vectors.value=4;d.copy_en.value=1
    await tick();d.copy_en.value=0
    assert int(d.error.value) and int(d.copy_done.value) and not int(d.qspi_req_val.value)
    for i,value in enumerate(snapshot):assert await vector(1016+i*2)==value
