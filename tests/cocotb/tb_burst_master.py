import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb.queue import Queue
import random

class AvalonMemory:
    def __init__(self, dut, name, size=1024*1024):
        self.dut = dut
        self.name = name
        self.mem = {} # Sparse memory map
        self.size = size
        self.log = dut._log

    def start_read_monitor(self):
        self.read_cmd_queue = Queue()
        cocotb.start_soon(self.read_command_monitor())
        cocotb.start_soon(self.read_data_driver())

    async def read_command_monitor(self):
        """Monitors Read Commands (Address Phase)"""
        while True:
            await RisingEdge(self.dut.clk)
            
            if random.random() < 0.1:
                self.dut.rm_waitrequest.value = 1
            else:
                self.dut.rm_waitrequest.value = 0
            
            if self.dut.rm_read.value == 1 and self.dut.rm_waitrequest.value == 0:
                addr = int(self.dut.rm_address.value)
                burst = int(self.dut.rm_burstcount.value)
                self.log.info(f"[{self.name}] Read Request Accepted: Addr=0x{addr:X}, Burst={burst}")
                self.read_cmd_queue.put_nowait((addr, burst))


    async def read_data_driver(self):
        """Drives Read Data (Data Phase)"""
        self.dut.rm_readdatavalid.value = 0
        self.dut.rm_readdata.value = 0
        
        while True:
            cmd = await self.read_cmd_queue.get()
            addr, burst = cmd
            
            self.log.info(f"[{self.name}] Data Driver: Starting burst Addr=0x{addr:X} Len={burst}")
            
            for i in range(burst):
                await RisingEdge(self.dut.clk)
                self.dut.rm_readdatavalid.value = 1
                data = self.mem.get(addr + (i*4), 0)
                self.dut.rm_readdata.value = data
            
            await RisingEdge(self.dut.clk)
            self.dut.rm_readdatavalid.value = 0


    async def write_monitor(self):
        """Monitors Write Master Interface"""
        burst_cnt = 0
        active_addr = 0
        
        while True:
            await RisingEdge(self.dut.clk)
            
            # Simple Accept
            self.dut.wm_waitrequest.value = 0
            
            if self.dut.wm_write.value == 1 and self.dut.wm_waitrequest.value == 0:
                addr = int(self.dut.wm_address.value)
                data = int(self.dut.wm_writedata.value)
                
                if burst_cnt == 0:
                    active_addr = addr
                    burst_len = int(self.dut.wm_burstcount.value)
                    self.log.info(f"[{self.name}] Write Start: Addr=0x{addr:X}, Len={burst_len}")
                
                effective_addr = active_addr + (burst_cnt * 4)
                self.mem[effective_addr] = data
                
                burst_cnt += 1
                if burst_cnt >= int(self.dut.wm_burstcount.value):
                     burst_cnt = 0 # Burst done

@cocotb.test()
async def test_burst_master_basic(dut):
    """Test Basic Burst Copy"""
    
    if dut._name == "burst_master_4":
        dut._log.info("Skipping basic copy test for burst_master_4 (Processing Pipeline Logic)")
        return
    
    # 1. Setup Clock
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    
    # 2. Reset
    dut.reset_n.value = 0
    dut.avs_write.value = 0
    dut.avs_read.value = 0
    dut.avs_address.value = 0
    dut.avs_writedata.value = 0
    dut.rm_waitrequest.value = 1
    dut.wm_waitrequest.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.reset_n.value = 1
    await RisingEdge(dut.clk)
    
    # 3. Setup Memory Models
    mem_model = AvalonMemory(dut, "MEM")
    
    # CSR Helper Functions
    async def write_csr(address, data):
        """Write to Avalon-MM CSR Slave"""
        await RisingEdge(dut.clk)
        dut.avs_address.value = address
        dut.avs_write.value = 1
        dut.avs_writedata.value = data
        await RisingEdge(dut.clk)
        dut.avs_write.value = 0
        dut.avs_address.value = 0

    async def read_csr(address):
        """Read from Avalon-MM CSR Slave"""
        await RisingEdge(dut.clk)
        dut.avs_address.value = address
        dut.avs_read.value = 1
        await RisingEdge(dut.clk)
        val = dut.avs_readdata.value
        dut.avs_read.value = 0
        return val

    # Populate Source Memory
    SRC_ADDR = 0x1000
    DST_ADDR = 0x5000
    BURST_SIZE = 256 # words
    TOTAL_BYTES = BURST_SIZE * 4 * 2 # 2 Bursts (512 words, 2KB)
    
    expected_data = []
    for i in range(0, TOTAL_BYTES, 4):
        val = i // 4 + 0xA000
        mem_model.mem[SRC_ADDR + i] = val
        expected_data.append(val)
        
    # Start Monitors
    mem_model.start_read_monitor()
    cocotb.start_soon(mem_model.write_monitor())
    
    # 4. Start Transaction via CSR
    dut._log.info("Configuring CSR Registers...")
    await write_csr(2, SRC_ADDR)
    await write_csr(3, DST_ADDR)
    await write_csr(4, TOTAL_BYTES)
    
    dut._log.info("Starting Transfer...")
    await write_csr(0, 1) # Start
    
    # 5. Wait for Done
    timeout = 20000
    while True:
        await RisingEdge(dut.clk)
        timeout -= 1
        if timeout % 10 == 0:
            status = await read_csr(1)
            if (int(status) & 1) == 1:
                break
        if timeout == 0:
            raise AssertionError("Timeout waiting for Done Status")
            
    dut._log.info("Transaction Done! (Status Bit Set)")
    await write_csr(1, 1) # Write 1 to clear
    
    # 6. Verify Memory
    for i in range(0, TOTAL_BYTES, 4):
        addr = DST_ADDR + i
        expected = expected_data[i // 4]
        read_val = mem_model.mem.get(addr, 0)
        
        if read_val != expected:
            raise AssertionError(f"Data Mismatch at {hex(addr)}: Expected {hex(expected)}, Got {hex(read_val)}")
            

    dut._log.info("Verification Complete!")

@cocotb.test()
async def test_burst_master_4_pipeline(dut):
    """Test Burst Master 4 Handshake Pipeline"""
    
    if dut._name != "burst_master_4":
        # Skip if not burst_master_4
        return

    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    
    # Reset
    dut.reset_n.value = 0
    await RisingEdge(dut.clk)
    dut.reset_n.value = 1
    await RisingEdge(dut.clk)
    
    # Avalon Memory Model (Shared)
    mem = {}
    
    # Read Master Monitor
    async def read_monitor(dut, mem):
        while True:
            await RisingEdge(dut.clk)
            if dut.rm_read.value == 1:
                addr = int(dut.rm_address.value)
                burst = int(dut.rm_burstcount.value)
                # Simple Request Ack
                dut.rm_waitrequest.value = 0
                await RisingEdge(dut.clk)
                dut.rm_waitrequest.value = 1
                
                # Send Data Back
                for i in range(burst):
                    await RisingEdge(dut.clk)
                    dut.rm_readdatavalid.value = 1
                    dut.rm_readdata.value = mem.get(addr + i*4, 0)
                await RisingEdge(dut.clk)
                dut.rm_readdatavalid.value = 0

    # Write Master Monitor
    async def write_monitor(dut, mem):
        dut.wm_waitrequest.value = 0 
        while True:
            await RisingEdge(dut.clk)
            if dut.wm_write.value == 1:
                addr = int(dut.wm_address.value)
                data = int(dut.wm_writedata.value)
                mem[addr] = data
                # Auto increment address logic in FSM handles next addr, 
                # but we need to track offset if random access... 
                # Actually FSM drives address per burst.
                # Here we just capture single writes? No, FSM holds address constant for burst?
                # Ah, standard Avalon-MM Master:
                # address is constant for burst if burstcount > 1? 
                # No, standard is: address is start of burst.
                # But here we are just capturing writedata.
                # We need to look at current offset. 
                # Let's simplify: The testbench simple model might be tricky.
                # Let's reuse the mem_model if possible or write simple one.

    # Reuse the class from the file if possible, or define simple one here.
    # The file has AvalonMemory class? I should check.
    # I'll rely on the existing AvalonMemory class in the file but I need to instantiate it.
    # Since I cannot see the class def in the last view, I assume it's available.
    
    # CSR Helpers
    async def write_csr(address, data):
        await RisingEdge(dut.clk)
        dut.avs_address.value = address
        dut.avs_write.value = 1
        dut.avs_writedata.value = data
        await RisingEdge(dut.clk)
        dut.avs_write.value = 0

    async def read_csr(address):
        await RisingEdge(dut.clk)
        dut.avs_address.value = address
        dut.avs_read.value = 1
        await RisingEdge(dut.clk)
        val = dut.avs_readdata.value
        dut.avs_read.value = 0
        return val

    # Initialize Memory
    SRC_ADDR = 0x1000
    DST_ADDR = 0x2000
    BURST_SIZE = 64
    TOTAL_BYTES = BURST_SIZE * 4 # 256 bytes
    COEFF = 3
    
    # We need to manually poke memory because we don't have the mem object easily accessible in this scope 
    # unless we instantiate the class.
    # Let's instantiate the class assuming it exists in the file scope.
    # from tb_burst_master import AvalonMemory # (It's in the same file)
    
    # Wait, simple trick: just set signals manually for memory if class is hard to use.
    # But better to use the class.
    # I saw AvalonMemory in previous `view_file` (lines 1-376).
    
    # Avalon Slave Logic (Simple)
    dut.rm_waitrequest.value = 1
    dut.wm_waitrequest.value = 1
    
    # Fork monitors
    # cocotb.start_soon(read_monitor(dut, mem)) ...
    # Actually, let's just use the logic from test_burst_master_basic
    # It seems it used a class `AvalonMemory`.
    
    # Let's assume AvalonMemory is available in global scope of this file.
    mem_model = AvalonMemory(dut, "mem_model")
    mem_model.start_read_monitor()
    cocotb.start_soon(mem_model.write_monitor())

    # Setup Data
    expected_data = []
    for i in range(0, TOTAL_BYTES, 4):
        val = ((i // 4) + 1) * 400
        mem_model.mem[SRC_ADDR + i] = val
        # Pipeline Logic: Stage 0 (Coeff), Stage 1 (/400 approx)
        intermediate = val * COEFF
        expected = (intermediate * 5243) >> 21
        expected_data.append(expected)

    dut._log.info(f"Configuring CSR with Coeff = {COEFF}")
    await write_csr(2, SRC_ADDR)
    await write_csr(3, DST_ADDR)
    await write_csr(4, TOTAL_BYTES)
    await write_csr(7, COEFF) # Coeff
    await write_csr(5, BURST_SIZE) # Rd Burst
    await write_csr(6, BURST_SIZE) # Wr Burst
    
    # Start
    await write_csr(0, 1)
    
    # Wait for Done
    for _ in range(2000):
        await RisingEdge(dut.clk)
        status = await read_csr(1)
        if (int(status) & 1):
            break
    else:
        raise AssertionError("Timeout")

    # Verify
    for i in range(0, TOTAL_BYTES, 4):
        addr = DST_ADDR + i
        expected = expected_data[i // 4]
        read_val = mem_model.mem.get(addr, 0)
        assert read_val == expected, f"Mismatch at {hex(addr)}: {read_val} != {expected}"

    dut._log.info("Handshake Pipeline Verification Complete!")


@cocotb.test()
async def test_programmable_burst(dut):
    """Test Programmable Burst Length (Read=64, Write=32)"""
    
    # Skip if not burst_master (basic)
    if dut._name != "burst_master":
        dut._log.info(f"Skipping programmable burst (addr map specific) for {dut._name}")
        # Assuming burst_master_2/3 might rely on same map, but let's test safely on burst_master first
        # Actually burst_master_2/3 don't have programmable logic implemented yet in this session, 
        # so this test would fail on them if they don't have the registers. 
        # But wait, I only modified burst_master.v!
        return

    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    
    # Reset
    dut.reset_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.reset_n.value = 1
    await RisingEdge(dut.clk)
    
    mem_model = AvalonMemory(dut, "MEM_PROG")
    mem_model.start_read_monitor()
    cocotb.start_soon(mem_model.write_monitor())

    # CSR Helper Functions
    async def write_csr(address, data):
        await RisingEdge(dut.clk)
        dut.avs_address.value = address
        dut.avs_write.value = 1
        dut.avs_writedata.value = data
        await RisingEdge(dut.clk)
        dut.avs_write.value = 0
        dut.avs_address.value = 0

    async def read_csr(address):
        await RisingEdge(dut.clk)
        dut.avs_address.value = address
        dut.avs_read.value = 1
        await RisingEdge(dut.clk)
        val = dut.avs_readdata.value
        dut.avs_read.value = 0
        return val

    # Test Config
    SRC_ADDR = 0x8000
    DST_ADDR = 0xC000
    READ_BURST = 64
    WRITE_BURST = 32
    TOTAL_BYTES = 512 # 8 Read Bursts, 16 Write Bursts
    
    expected_data = []
    for i in range(0, TOTAL_BYTES, 4):
        val = i // 4 + 0xB000
        mem_model.mem[SRC_ADDR + i] = val
        expected_data.append(val)

    dut._log.info(f"Configuring Programmable Burst: Read={READ_BURST}, Write={WRITE_BURST}")
    await write_csr(5, READ_BURST) # Set Read Burst Count
    await write_csr(6, WRITE_BURST) # Set Write Burst Count
    
    # Verify Readback
    rb_rd = await read_csr(5)
    rb_wr = await read_csr(6)
    dut._log.info(f"Readback Config: Read={int(rb_rd)}, Write={int(rb_wr)}")
    
    assert int(rb_rd) == READ_BURST, f"CSR Readback Failed: Expected {READ_BURST}, Got {int(rb_rd)}"
    assert int(rb_wr) == WRITE_BURST, f"CSR Readback Failed: Expected {WRITE_BURST}, Got {int(rb_wr)}"

    await write_csr(2, SRC_ADDR)
    await write_csr(3, DST_ADDR)
    
    # Test Padding Logic with Non-256 burst
    # If we request Length = 100, and Read Burst is 64 (256 bytes):
    # Padding should be (100 + 255) & ~255 = 256.
    # Let's try slightly unaligned length
    REQ_LEN = TOTAL_BYTES - 4 # 508 bytes
    # Padding logic: (508 + (64*4 - 1)) & ~(64*4 - 1)
    # (508 + 255) & ~255 = 763 & 0xFFFFFF00 = 0x200 = 512.
    # So effective length should be 512.
    
    await write_csr(4, REQ_LEN)
    eff_len = await read_csr(4)
    dut._log.info(f"Requested Len: {REQ_LEN}, Effective Len: {int(eff_len)}")
    
    assert int(eff_len) == TOTAL_BYTES, f"Padding Logic Failed: Expected {TOTAL_BYTES}, Got {int(eff_len)}"
    
    await write_csr(0, 1) # Start
    
    # Wait for Done
    timeout = 20000
    while True:
        await RisingEdge(dut.clk)
        timeout -= 1
        if timeout % 10 == 0:
            status = await read_csr(1)
            if (int(status) & 1) == 1:
                break
        if timeout == 0:
            raise AssertionError("Timeout waiting for Done Status")

    dut._log.info("Transaction Done!")
    
    # Verify Data
    for i in range(0, TOTAL_BYTES, 4):
        addr = DST_ADDR + i
        expected = expected_data[i // 4]
        read_val = mem_model.mem.get(addr, 0)
        
        if read_val != expected:
            raise AssertionError(f"Data Mismatch at {hex(addr)}: Expected {hex(expected)}, Got {hex(read_val)}")

    dut._log.info("Programmable Burst Verification Complete!")
