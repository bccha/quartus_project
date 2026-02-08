import cocotb
from cocotb.triggers import RisingEdge, Timer
from cocotb.clock import Clock

async def reset_dut(reset_n, duration_ns):
    reset_n.value = 0
    await Timer(duration_ns, unit="ns")
    reset_n.value = 1
    await Timer(duration_ns, unit="ns")

@cocotb.test()
async def test_avs_read_write(dut):
    """Test Basic Avalon-MM Read and Write operations"""
    
    # 1. Start Clock (50MHz)
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    
    # 2. Reset
    await reset_dut(dut.reset_n, 40)
    await RisingEdge(dut.clk)
    
    # 3. Write Data (Address 5, Value 0xDEADBEEF)
    dut.address.value = 5
    dut.writedata.value = 0xDEADBEEF
    dut.write.value = 1
    dut.read.value = 0
    await RisingEdge(dut.clk)
    dut.write.value = 0
    
    # 4. Wait a cycle
    await RisingEdge(dut.clk)
    
    # 5. Read Data (Address 5)
    dut.address.value = 5
    dut.read.value = 1
    await RisingEdge(dut.clk)
    
    # Avalon-MM Latency: readdata is valid 1 cycle after read assertion
    # Based on my_slave.v: readdatavalid <= read
    dut.read.value = 0
    await RisingEdge(dut.clk)
    
    readdata = dut.readdata.value
    valid = dut.readdatavalid.value
    
    dut._log.info(f"Read Data: {hex(readdata)}, Valid: {valid}")
    
    assert valid == 1, "readdatavalid should be 1"
    assert readdata == 0xDEADBEEF, f"Expected 0xDEADBEEF, got {hex(readdata)}"

    # 6. Random R/W Sequence
    for i in range(10):
        addr = i
        val = 0x100 + i
        
        # Write
        dut.address.value = addr
        dut.writedata.value = val
        dut.write.value = 1
        await RisingEdge(dut.clk)
        dut.write.value = 0
        
        # Read
        dut.read.value = 1
        await RisingEdge(dut.clk)
        dut.read.value = 0
        await RisingEdge(dut.clk) # Wait for readdatavalid
        
        res = dut.readdata.value
        dut._log.info(f"Addr {addr}: Wrote {hex(val)}, Read {hex(res)}")
        assert res == val, f"Mismatch at addr {addr}"
