import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb.queue import Queue
# from cocotb.result import TestFailure, TestSuccess # Removed
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
            
            # Random waitrequest to simulate backpressure?
            # For back-to-back test, we want to be fast mostly.
            # But let's add occasional wait.
            if random.random() < 0.1:
                self.dut.rm_waitrequest.value = 1
            else:
                self.dut.rm_waitrequest.value = 0
            
            # Check if command is valid
            # In Avalon MM, if waitrequest is 0 and read is 1, command is accepted.
            # BUT we just set waitrequest=0/1 combinatorially for *this* cycle.
            # Wait, signals are sampled at RisingEdge.
            # So if we set waitrequest now, it takes effect at NEXT edge?
            # Cocotb timing: 
            # await RisingEdge -> we are just after clock edge.
            # dut.rm_read is valid for THIS cycle.
            # dut.rm_waitrequest was set in PREVIOUS cycle.
            # So we check if read=1 and PREVIOUS waitrequest=0.
            
            # To simulate slave correctly:
            # We drive waitrequest.
            # Master drives read.
            # At clock edge, both overlap.
            
            # Let's keep it simple: strict 0 waitrequest usually.
            self.dut.rm_waitrequest.value = 0
            
            # Need to wait for read signal to settle? No, it's synchronous.
            # But waitrequest must be stable.
            
            if self.dut.rm_read.value == 1:
                addr = int(self.dut.rm_address.value)
                burst = int(self.dut.rm_burstcount.value)
                self.log.info(f"[{self.name}] Read Request Accepted: Addr=0x{addr:X}, Burst={burst}")
                self.read_cmd_queue.put_nowait((addr, burst))
                
                # If we want to simulate waitrequest assertion *after* command acceptance:
                # self.dut.rm_waitrequest.value = 1
                # But for pipelined slave, we can accept back-to-back.
                # So we keep waitrequest=0 unless we are full or random.


    async def read_data_driver(self):
        """Drives Read Data (Data Phase)"""
        self.dut.rm_readdatavalid.value = 0
        self.dut.rm_readdata.value = 0
        
        while True:
            cmd = await self.read_cmd_queue.get()
            addr, burst = cmd
            
            # Log data phase start
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
            
            if self.dut.wm_write.value == 1:
                addr = int(self.dut.wm_address.value)
                data = int(self.dut.wm_writedata.value)
                
                # Check if new burst or continuation?
                # The DUT asserts write for EACH word in the burst?
                # My RTL: Assert write for each word. Address stays constant? 
                # Wait, standard Avalon MM Burst:
                # "In the description of a burst, 'address' usually refers to the address of the FIRST item."
                # However, for "Pipelined with Variable Latency", the master asserts Write for each data item.
                # If it is a burst, the address *can* increment or stay constant depending on slave?
                # Usually Master increments address if it's not a fixed-location slave.
                # But `burst_master.v` as written: `wm_address` is set at start of burst.
                # And `wm_write` is High for BURST_COUNT cycles.
                
                # My RTL implementation:
                # `wm_address` <= `current_dst_addr` (Set once at start of burst)
                # `wm_write` <= 1 (Held High for `BURST_COUNT` cycles)
                # `wm_word_cnt` increments.
                
                # So the address line logic in RTL does NOT increment per beat.
                # This implies the Slave must handle the burst addressing.
                # Let's assume Slave calculates addr = base + offset.
                
                if burst_cnt == 0:
                    active_addr = addr
                    # Capture burst count? (The RTL holds it constant)
                    burst_len = int(self.dut.wm_burstcount.value)
                    self.log.info(f"[{self.name}] Write Start: Addr=0x{addr:X}, Len={burst_len}")
                
                # Create offset-based address
                effective_addr = active_addr + (burst_cnt * 4)
                self.mem[effective_addr] = data
                # self.log.info(f"[{self.name}] Wrote: 0x{effective_addr:X} = 0x{data:X}")
                
                burst_cnt += 1
                if burst_cnt >= int(self.dut.wm_burstcount.value):
                     burst_cnt = 0 # Burst done
            else:
                # reset burst tracking if write goes low?
                if burst_cnt != 0:
                    # Should not verify this if we support breaks, but RTL is continuous
                    pass

@cocotb.test()
async def test_burst_master_basic(dut):
    """Test Basic Burst Copy"""
    
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
        await RisingEdge(dut.clk) # Wait one cycle (latency 0/1?)
        # Simple register read is usually 0 latency in standard RTL if just mux, 
        # but let's assume 1 cycle from read assert to data valid if registered?
        # My RTL logic: always @(*) case(avs_address). Combinational read.
        # So data should be valid in the same cycle if avs_read is high?
        # But signals are sampled at edge.
        # Let's check logic:
        # always @(*) case(avs_address) ...
        # So if I set address/read at Cycle N (Rising Edge), 
        # at Cycle N+1 (Rising Edge) the returned data should be captured?
        # Actually in Cocotb, if I set signals, they update immediately (delta cycle).
        # So 'dut.avs_readdata.value' should be valid after simple yield if combinational.
        # But to be safe and mimic bus master:
        # Cycle 1: Assert Read/Addr
        # Cycle 2: Deassert Read, Sample Data
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
    # Register Map:
    # 0: Control (Bit 0 Start)
    # 1: Status (Bit 0 Done)
    # 2: Src Addr
    # 3: Dst Addr
    # 4: Len
    
    # Init CSR signals
    dut.avs_write.value = 0
    dut.avs_read.value = 0
    dut.avs_address.value = 0
    dut.avs_writedata.value = 0
    
    dut._log.info("Configuring CSR Registers...")
    await write_csr(2, SRC_ADDR)
    await write_csr(3, DST_ADDR)
    await write_csr(4, TOTAL_BYTES)
    
    dut._log.info("Starting Transfer...")
    await write_csr(0, 1) # Start
    
    # 5. Wait for Done (Polling Status Register)
    timeout = 10000
    while True:
        await RisingEdge(dut.clk)
        
        # Poll Status every 10 cycles
        timeout -= 1
        if timeout % 10 == 0:
            status = await read_csr(1)
            # dut._log.info(f"Status: {status}")
            if (int(status) & 1) == 1:
                break
        
        if timeout == 0:
            raise AssertionError("Timeout waiting for Done Status")
            
    dut._log.info("Transaction Done! (Status Bit Set)")
    
    # Clear Done?
    await write_csr(1, 1) # Write 1 to clear
    
    # 6. Verify Memory
    
    # 6. Verify Memory
    for i in range(0, TOTAL_BYTES, 4):
        addr = DST_ADDR + i
        expected = expected_data[i // 4]
        read_val = mem_model.mem.get(addr, 0)
        
        if read_val != expected:
            raise AssertionError(f"Data Mismatch at {hex(addr)}: Expected {hex(expected)}, Got {hex(read_val)}")
            
    dut._log.info("Verification Complete!")

@cocotb.test()
async def test_burst_master_processing(dut):
    """Test Burst Master 3 Processing Capabilities"""
    
    # Only run this test for burst_master_3
    if dut._name != "burst_master_3":
        dut._log.info(f"Skipping processing test for {dut._name}")
        return

    # 1. Clock Generation
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
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

    # Setup Source Memory
    SRC_ADDR = 0x2000
    DST_ADDR = 0x6000
    BURST_SIZE = 256 
    TOTAL_BYTES = BURST_SIZE * 4 # 1 Burst for simple test
    COEFF = 3
    
    expected_data = []
    for i in range(0, TOTAL_BYTES, 4):
        val = i // 4 + 10 # Some Value
        mem_model.mem[SRC_ADDR + i] = val
        expected_data.append(val * COEFF) # Expected is Value * Coeff
        
    mem_model.start_read_monitor()
    cocotb.start_soon(mem_model.write_monitor())
    
    # 4. Configure CSR with Coefficient
    dut._log.info(f"Configuring CSR with Coeff = {COEFF}")
    await write_csr(2, SRC_ADDR)
    await write_csr(3, DST_ADDR)
    await write_csr(4, TOTAL_BYTES)
    await write_csr(5, COEFF) # Set Coeff
    
    # 5. Start
    dut._log.info("Starting Transfer...")
    await write_csr(0, 1) # Start
    
    # 6. Wait for Done
    timeout = 5000
    while True:
        await RisingEdge(dut.clk)
        timeout -= 1
        if timeout % 10 == 0:
            status = await read_csr(1)
            if (int(status) & 1) == 1:
                break
        if timeout == 0:
            raise AssertionError("Timeout waiting for Done")
            
    dut._log.info("Transaction Done! Verifying Data...")
    
    # 7. Verify Memory
    for i in range(0, TOTAL_BYTES, 4):
        addr = DST_ADDR + i
        expected = expected_data[i // 4] & 0xFFFFFFFF # Truncate to 32-bit
        read_val = mem_model.mem.get(addr, 0)
        
        if read_val != expected:
            raise AssertionError(f"Data Mismatch at {hex(addr)}: Expected {hex(expected)}, Got {hex(read_val)}")
            
    dut._log.info("Processing Verification Complete!")
