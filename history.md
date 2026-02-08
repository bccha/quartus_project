# FPGA Project Verification: From Custom Slave to Hardware Acceleration

**Date:** 2026-02-06
**Project Path:** `c:/Workspace/quartus_project`

---

## Introduction
This document records the development journey of building a Nios II-based SoC on an Intel FPGA. The project focuses on two key hardware components: a memory-mapped Custom Slave interface and a high-performance Custom Instruction unit for arithmetic acceleration. This isn't just a changelog—it's a deep dive into *why* we built it this way.

---

## Chapter 1: The Custom Slave Interface (Avalon-MM)

### The Challenge: "Structural Net Expression" Error
When integrating a Dual-Port RAM (DPRAM) as a slave module, we initially encountered a common Verilog error: *"Output port must be connected to a structural net expression."*
This happened because we declared the output `readdata` as a `reg` type, but tried to connect it directly to the output of the instantiated `dpram` module. In Verilog, module instances drive wires, not registers.

### The Solution: Wire & Valid Logic
We switched `readdata` to `wire` to allow direct connection. Additionally, the Avalon-MM protocol requires explicit read latency management. Since our blockRAM reading takes 1 clock cycle, we implemented a synchronous `readdatavalid` signal that asserts exactly one cycle after the read request.

**Implementation (`RTL/my_slave.v`):**
```verilog
module my_custom_slave (
    // ... ports ...
    output wire [31:0] readdata,   // Changed from reg to wire
    output reg         readdatavalid // Added for Avalon-MM latency
);
    
    // Direct connection to DPRAM instance
    dpram dpram_inst (
        .clock(clk),        
        .rdaddress(address),
        // ...
        .q(readdata) // dpram drives this wire directly
    );
   
    // Synchronous Valid Generation (1 Cycle Latency)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin            
            readdatavalid <= 1'b0;
        end else begin           
            readdatavalid <= read; // Pass-through with 1 cycle delay
        end
    end
endmodule
```

### Under the Hood: Internal Memory (DPRAM)
To give our Custom Slave meaningful functionality, we embedded a **Dual-Port RAM (DPRAM)**. Unlike flip-flop based registers, DPRAM utilizes the FPGA's dedicated memory blocks (M10K/M9K), allowing for efficient, high-density storage.

*   **Why Dual-Port?**
    It enables simultaneous access from two different ports. In a more complex scenario, one port could be connected to the Nios II processor (via this Avalon slave) while the other port collects high-speed data from sensors or hardware logic independently.
*   **The "Structural" Connection:**
    As mentioned in the error resolution, the `dpram` module is a structural entity. Its `q` (output) port drives a wire, which flows directly out to the Avalon interface's `readdata` bus. **Critically, you must NOT attach a register (`reg`) to the `q` output.** The `dpram` instantiation already drives this signal structurally; attempting to latch it into a `reg` block within the same module triggers the "structural net expression" compilation error.

![DPRAM Internal Architecture](./images/image_dpram.png)
*(Figure: Internal structure of the Custom Slave showing DPRAM integration)*

### Address Alignment: Byte vs. Word
A critical implementation detail often overlooked is how the CPU's address matches the RAM's address.

*   **The Conflict**:
    *   **Nios II (Master)**: Uses **Byte Addressing**. To read consecutive 32-bit integers, it issues addresses `0x00`, `0x04`, `0x08`, `0x0C`.
    *   **DPRAM (Internal)**: Uses **Word Indexing**. Slot 0 is data A, Slot 1 is data B. It expects `0`, `1`, `2`, `3`.
*   **The Resolution (Qsys)**:
    We configured the Avalon-MM Pipeline Slave in Platform Designer to use **Address Units: WORDS**.
    *   **How it works**: The system interconnect automatically shifts the master's byte address right by 2 bits (`Address >> 2`) before asserting our module's `address` input.
    *   **Result**: When the CPU tries to read `0x04` (Byte Address 4), our `my_slave.v` receives `1` on the `address` line. This allows us to connect the input `address` **directly** to the DPRAM's `rdaddress` port without needing manual bit slicing (e.g., `address[9:2]`) in the Verilog code.

---

## Chapter 2: Hardware Acceleration (Custom Instruction)

### The Goal: Fast Division
Standard Nios II processors do not have a hardware floating-point unit by default, and integer division is computationally expensive (taking many cycles). We needed a way to perform specific arithmetic operations—specifically, multiplying two numbers and then dividing the result by 400—extremely fast.

### The Optimization: Shift-Add Instead of Division
Hardware dividers consume significant logic resources and timing budget. Instead of a raw divider, we used a mathematical approximation using **Bit-Shifting and Addition**.

**The Math:**
We want to calculate $result = (A \times B) / 400$.
Division by 400 is approximately multiplication by $0.0025$.
We found that multiplying by $1311$ and right-shifting by $19$ bits gives an incredibly close approximation:

$$ \frac{1311}{2^{19}} = \frac{1311}{524288} \approx 0.00250053 $$

This results in an error of only **0.02%**, which is acceptable for our application.
We construct the number $1311$ using powers of 2 to avoid a general multiplier:
$$ 1311 = 1024 + 256 + 32 - 1 = (2^{10} + 2^8 + 2^5 - 2^0) $$

**Implementation (`RTL/my_multi_calc.v`):**
```verilog
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mult_stage <= 0;
            result <= 0;
        end 
        else if (clk_en) begin
            // [Cycle 1] Hardware Multiplier
            mult_stage <= 64'd1 * dataa * datab;
            
            // [Cycle 2] Optimization: Replace Division with Shift-Add
            // Logic: (val * 1311) >> 19
            result <= ((mult_stage << 10) + (mult_stage << 8) + (mult_stage << 5) - mult_stage) >> 19;      
        end
    end
```

---

## Chapter 3: System Integration & DMA

### High-Speed Data Movement (DMA)
Nios II processors can be slow at copying large buffers. We integrated an **Altera Scatter-Gather DMA Controller** to offload bulk data transfers between On-Chip Memory and the Custom Slave.

### Evolution: Modular SGDMA
To perform calculations **during** data movement (inline processing), we transitioned to **Modular SGDMA**. This split architecture allows us to insert our `stream_processor` logic directly into the data path between the Read Master and Write Master.

#### Streaming Pipeline Control (Valid-Ready Handshake)
The core of the **Stream Processor** (`stream_processor.v`) design is robust flow control using the Avalon-Streaming interface.

**Pipeline Control Logic (Backpressure Chain):**
In our 3-stage pipeline, the `Ready` signal propagates backwards from the sink to the source to ensure no data is lost when the downstream is busy.

```verilog
// 1. Stage 2 (Final) Ready:
assign pipe_ready[2] = (!pipe_valid[2]) || aso_ready;

// 2. Stage 1 (Middle) Ready:
assign pipe_ready[1] = (!pipe_valid[1]) || pipe_ready[2];

// 3. Stage 0 (Initial) Ready:
assign pipe_ready[0] = (!pipe_valid[0]) || pipe_ready[1];

// Feed back to Sink
assign asi_ready = pipe_ready[0];
```

---

## Chapter 4: Troubleshooting & Lessons Learned

### 1. HAL Driver Limits: Direct CSR Control
*   **Issue**: `alt_msgdma_open()` returned `NULL`.
*   **Solution**: Used `IOWR` macros to control the **Modular SGDMA Dispatcher** directly via its **Control Status Register (CSR)**.

### 2. Endianness Trap
> [!WARNING]
> Nios II is **Little-Endian**. If your data looks scrambled (e.g., 400 becomes `0x90010000`), it is likely because the Avalon-ST Sink has "First Symbol In High-Order Bits" enabled.
*   **Fix**: Implement a **Byte Swap** in the first pipeline stage of your RTL to align with the CPU's memory layout.

---

## Chapter 5: Final Results & Evolution

### Benchmarking Results
Benchmarks on the Nios II confirm major performance gains:
*   **Bypass Mode**: 7.59x faster than CPU copy.
*   **Multiplication Mode**: **86.14x faster** than software-emulated division!

### Evolution to N-Stage Pipeline
The project concluded by refactoring the logic into a parameterizable **N-Stage Pipeline**.
*   **3 Stages**: (0) Input/Byte Swap, (1) Multiplier, (2) Reciprocal Mult & Output Swap.
*   **Outcome**: Improved timing margins and industrial-grade stability.

---

## Closing Thoughts
By combining **Custom Instructions**, **mSGDMA**, and **RTL Optimization**, we transformed a standard processor into a high-performance system. This record serves as a comprehensive guide for future FPGA SoC designs.
