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

    async def read_monitor(self):
        """Monitors Read Master Interface"""
        while True:
            await RisingEdge(self.dut.clk)
            
            # Default
            self.dut.rm_readdatavalid.value = 0
            self.dut.rm_readdata.value = 0
            
            # Simple Slave: Always accept command if not valid, or random wait?
            # Let's be a clean slave first.
            if self.dut.rm_read.value == 1:
                try:
                    addr = int(self.dut.rm_address.value)
                    burst = int(self.dut.rm_burstcount.value)
                except ValueError:
                    self.log.error(f"[{self.name}] Invalid Read Req: rm_read={self.dut.rm_read.value}, rm_address={self.dut.rm_address.value}, rm_burstcount={self.dut.rm_burstcount.value}")
                    # Force default to verify if it continues? No, raise error but log details first.
                    raise
                
                self.log.info(f"[{self.name}] Read Request: Addr=0x{addr:X}, Burst={burst}")
                
                # Accept command
                self.dut.rm_waitrequest.value = 0
                await RisingEdge(self.dut.clk) 
                
                # Now BUSY processing data. Assert waitrequest to block new commands
                # (Simple model: Single Outstanding Transaction support)
                self.dut.rm_waitrequest.value = 1
                
                # Return data
                for i in range(burst):
                    await RisingEdge(self.dut.clk) # Latency
                    self.dut.rm_readdatavalid.value = 1
                    data = self.mem.get(addr + (i*4), 0)
                    self.dut.rm_readdata.value = data
                
                await RisingEdge(self.dut.clk)
                self.dut.rm_readdatavalid.value = 0
                
                # Done, release waitrequest
                self.dut.rm_waitrequest.value = 0
            else:
                self.dut.rm_waitrequest.value = 0


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
    dut.ctrl_start.value = 0
    dut.rm_waitrequest.value = 1
    dut.wm_waitrequest.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.reset_n.value = 1
    await RisingEdge(dut.clk)
    
    # 3. Setup Memory Models
    mem_model = AvalonMemory(dut, "MEM")
    
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
    cocotb.start_soon(mem_model.read_monitor())
    cocotb.start_soon(mem_model.write_monitor())
    
    # 4. Start Transaction
    dut.ctrl_src_addr.value = SRC_ADDR
    dut.ctrl_dst_addr.value = DST_ADDR
    dut.ctrl_len.value = TOTAL_BYTES
    dut.ctrl_start.value = 1
    
    await RisingEdge(dut.clk)
    dut.ctrl_start.value = 0
    
    # 5. Wait for Done
    timeout = 10000
    while dut.ctrl_done.value == 0:
        await RisingEdge(dut.clk)
        timeout -= 1
        if timeout == 0:
            raise AssertionError("Timeout waiting for ctrl_done")
            
    dut._log.info("Transaction Done!")
    
    # 6. Verify Memory
    for i in range(0, TOTAL_BYTES, 4):
        addr = DST_ADDR + i
        val = mem_model.mem.get(addr, 0xFFFFFFFF)
        exp = expected_data[i//4]
        if val != exp:
             dut._log.error(f"Mismatch at 0x{addr:X}: Exp 0x{exp:X}, Got 0x{val:X}")
             raise AssertionError(f"Mismatch at 0x{addr:X}: Exp 0x{exp:X}, Got 0x{val:X}")
             
    dut._log.info("Verification Successful!")

