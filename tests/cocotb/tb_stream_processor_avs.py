import cocotb
from cocotb.triggers import RisingEdge, Timer
from cocotb.clock import Clock

async def reset_dut(reset_n, duration_ns):
    reset_n.value = 0
    await Timer(duration_ns, unit="ns")
    reset_n.value = 1
    await Timer(duration_ns, unit="ns")

@cocotb.test()
async def test_stream_processor_avs(dut):
    """Test Avalon-MM Slave interface of stream_processor"""
    
    # Start Clock (50MHz)
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    
    # Reset
    await reset_dut(dut.reset_n, 40)
    await RisingEdge(dut.clk)

    # 1. Read VERSION (Default value of coeff_a at addr 0)
    dut.avs_address.value = 0
    dut.avs_read.value = 1
    await RisingEdge(dut.clk)
    dut.avs_read.value = 0
    
    await RisingEdge(dut.clk) # Latency for readdatavalid
    version = int(dut.avs_readdata.value)
    dut._log.info(f"Read Version from coeff_a: {hex(version)}")
    assert version == 0x00000110, f"Expected 0x110, got {hex(version)}"
    assert dut.avs_readdatavalid.value == 1, "avs_readdatavalid should be 1"

    # 2. Write and Read coeff_a (addr 0)
    test_coeff = 0x12345678
    dut.avs_address.value = 0
    dut.avs_writedata.value = test_coeff
    dut.avs_write.value = 1
    await RisingEdge(dut.clk)
    dut.avs_write.value = 0
    
    # Verify write by reading it back
    dut.avs_read.value = 1
    await RisingEdge(dut.clk)
    dut.avs_read.value = 0
    await RisingEdge(dut.clk)
    
    read_coeff = int(dut.avs_readdata.value)
    dut._log.info(f"Read coeff_a: {hex(read_coeff)}")
    assert read_coeff == test_coeff, f"Expected {hex(test_coeff)}, got {hex(read_coeff)}"

    # 3. Write and Read bypass (addr 1)
    dut.avs_address.value = 1
    dut.avs_writedata.value = 1
    dut.avs_write.value = 1
    await RisingEdge(dut.clk)
    dut.avs_write.value = 0
    
    dut.avs_read.value = 1
    await RisingEdge(dut.clk)
    dut.avs_read.value = 0
    await RisingEdge(dut.clk)
    
    read_bypass = int(dut.avs_readdata.value)
    dut._log.info(f"Read bypass: {read_bypass}")
    assert read_bypass == 1, f"Expected 1, got {read_bypass}"

    # 4. Read read-only registers (asi_valid_count at addr 2, last_asi_data at addr 3)
    # These should be 0 because we haven't sent any ST data yet
    dut.avs_address.value = 2
    dut.avs_read.value = 1
    await RisingEdge(dut.clk)
    dut.avs_read.value = 0
    await RisingEdge(dut.clk)
    
    count = int(dut.avs_readdata.value)
    dut._log.info(f"Read asi_valid_count: {count}")
    assert count == 0

    dut.avs_address.value = 3
    dut.avs_read.value = 1
    await RisingEdge(dut.clk)
    dut.avs_read.value = 0
    await RisingEdge(dut.clk)
    
    last_data = int(dut.avs_readdata.value)
    dut._log.info(f"Read last_asi_data: {last_data}")
    assert last_data == 0
