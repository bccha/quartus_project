# FPGA Project Verification: From Custom Slave to Hardware Acceleration

**Date:** 2026-02-06
**Project Path:** `c:/Workspace/quartus_project`

---

## Introduction
This document records the development process of building a Nios II-based SoC on an Intel FPGA. This project focuses on two key hardware components: a memory-mapped Custom Slave interface and a high-performance Custom Instruction unit for arithmetic acceleration. It is not just a simple change log (Changelog), but an in-depth technical record of **why** it was designed this way.

---

## Chapter 1: Custom Slave Interface (Avalon-MM)

### Challenge: "Structural Net Expression" Error
In the process of integrating a Dual-Port RAM (DPRAM) inside the slave module, we faced a common Verilog error: *"Output port must be connected to a structural net expression"*.
This error occurred because the `readdata` output port was declared as a `reg` type and tried to be directly connected to the output of the internally instantiated `dpram` module. In Verilog, module instances must drive a wire, not a register (reg).

### Solution: Wire Conversion and Valid Logic Addition
To solve this problem, we changed `readdata` to a `wire` type so it could be directly connected. Additionally, the Avalon-MM protocol requires explicit read latency management. Since our BlockRAM read takes 1 clock cycle, we implemented a synchronous `readdatavalid` signal that becomes `1` exactly 1 cycle after the read request.

**Implementation Code (`RTL/my_slave.v`):**
```verilog
module my_custom_slave (
    // ... ports ...
    output wire [31:0] readdata,   // Changed from reg to wire
    output reg         readdatavalid // Added for Avalon-MM latency processing
);
    
    // Direct connection to DPRAM instance
    dpram dpram_inst (
        .clock(clk),        
        .rdaddress(address),
        // ...
        .q(readdata) // dpram drives this wire directly
    );
   
    // Synchronous Valid generation (1 cycle delay)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin            
            readdatavalid <= 1'b0;
        end else begin           
            readdatavalid <= read; // Passed with a 1-cycle delay
        end
    end
 endmodule
```

### Internal Structure: Built-in Memory (DPRAM)
To give practical functionality to the custom slave, we embedded a **Dual-Port RAM (DPRAM)**. Unlike flip-flop-based registers, DPRAM efficiently provides high-density storage space using the FPGA's dedicated memory blocks (M10K/M9K).

*   **Why Dual-Port?**
    Because it allows simultaneous access from two different ports. In a more complex scenario, one port is connected to the Nios II processor (via this Avalon slave), and the other port can independently collect high-speed data from sensors or hardware logic.
*   **"Structural" Connection Cautions:**
    As in the error resolution process mentioned earlier, the `dpram` module is a structural entity. The `q` (output) port drives a wire, and this wire is directly connected to the Avalon interface's `readdata` bus. **Important: You must not attach a register (`reg`) to the `q` output.** The `dpram` instance is already driving the signal structurally, so trying to latch it again into a `reg` block within the same module causes a compilation error.

![DPRAM Internal Architecture](./images/image_dpram.png)
*(Figure: Internal structure of the Custom Slave with integrated DPRAM)*

### Address Alignment: Byte vs. Word
An important detail often overlooked during implementation is how to align the CPU address with the RAM address.

*   **Conflict Point**:
    *   **Nios II (Master)**: Uses **Byte Addressing**. When reading consecutive 32-bit integers, the address increases as `0x00`, `0x04`, `0x08`, `0x0C`.
    *   **DPRAM (Internal)**: Uses **Word Indexing**. It is in the order of slot 0, slot 1, and expects `0`, `1`, `2`, `3`.
*   **Solution (Qsys Setting)**:
    In Platform Designer, we selected **Address Units: WORDS** in the Avalon-MM Pipeline Slave settings.
    *   **Operation Principle**: The system interconnect automatically shifts the master's byte address 2 bits to the right (`Address >> 2`) and passes it to the module's `address` input.
    *   **Result**: When the CPU tries to read `0x04` (byte address 4), `my_slave.v` receives `1` as the `address` input. Therefore, you can **directly** connect the input `address` to the DPRAM's `rdaddress` port without separate bit slicing (e.g., `address[9:2]`) in the Verilog code.

---

## Chapter 2: Hardware Acceleration (Custom Instruction)

### Goal: High-speed Division
Standard Nios II processors do not have a hardware floating-point unit by default, and integer division is computationally very expensive (takes many cycles). We needed a way to extremely quickly process a specific arithmetic operation of multiplying two numbers and then dividing by 400.

### Optimization: Use Shift-Add Instead of Division
Hardware dividers consume significant logic resources and timing budget. Instead of using a raw divider, we adopted a mathematical approximation method using **bit shift and multiplication (Shift-Add)**.

**Mathematical Principle:**
We want to calculate $result = (A \times B) / 400$.
Dividing by 400 is similar to multiplying by 0.0025.
We chose $Q=21$ for even higher precision. We found that multiplying by 5243 and shifting to the right by 21 bits gives a very precise approximation:

$$ \frac{5243}{2^{21}} = \frac{5243}{2097152} \approx 0.00249995 $$

The error of this method is only **0.0018%**, which is almost negligible for our application.

**Implementation Code (`RTL/my_multi_calc.v`):**
```verilog
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mult_stage <= 0;
            result <= 0;
        end 
        else if (clk_en) begin
            // [Cycle 1] Hardware Multiplication
            mult_stage <= 64'd1 * dataa * datab;
            
            // [Cycle 2] Optimization: Use Shift-Add instead of divider (K=5243, Q=21)
            // Logic: (val * 5243) >> 21
            result <= (mult_stage * 64'd5243) >> 21;      
        end
    end
```

### Timing Error Analysis and Optimization
At the time of initial implementation, a **Setup Time Violation (Timing Error)** occurred. Analysis of the cause of this problem and its solution is as follows.

#### Problem Cause: Critical Path of the Divider
In hardware, the **division (/) operation** has a much deeper combinational logic depth compared to addition or multiplication.
*   We attempted to process 32-bit division within a **single clock (1 Cycle)**.
*   The signal propagation delay (Data Path Delay) through the division circuit exceeded the clock period (e.g., 50MHz, 20ns).
*   This caused a **Setup Time Violation** where the data did not arrive at the register on time.

#### Solution: Shift-Add Approximation Operation
The **DSP block (Multiplier)** inside the FPGA is very fast, but the divider is slow. Therefore, we solved the Timing issue by converting the division into **multiplication and shift operations**.

*   **Before**: `Result = (A * B) / 400` (Using divider -> slow, Timing Error)
*   **After**: `Result = ((A * B) * 1311) >> 19` (Multiplier + shift -> fast, Timing Pass)

Through this change, we significantly shortened the Critical Path, resolved the Timing Violation, and were able to secure an operation speed of 50MHz or higher.

---

## Chapter 3: System Integration


### Top-Level Wiring
Finally, these modules are merged into one in the top-level entity. The `custom_inst_qsys` system generated by Platform Designer acts as the brain, and our custom HDL modules perform the role of muscles.

**Core Integration Code (`RTL/top_module.v`):**
```verilog
    // Qsys system instantiation
	custom_inst_qsys u0 (
		.clk_clk       (CLOCK_50),
		.reset_reset_n (RST),  
        // ... Avalon-MM signal connection ...
		.mmio_exp_readdata      (w_readdata),
		.mmio_exp_readdatavalid (w_readdatavalid), // Connected to our slave
        // ...
	);

    // Custom slave instantiation
	my_custom_slave s1 (
		.clk(CLOCK_50),
		.readdata(w_readdata), // Feedback to Qsys
		.readdatavalid(w_readdatavalid)
        // ...
	);
```

---

## Appendix: Platform Designer Setup Guide
To integrate the accelerator (`my_multi_calc.v`) into the Nios II system, please follow these steps in Platform Designer.

**Step 1: Create New Component**
*   Create a new component and verify the block symbol.
    ![Block Symbol](./images/image_block.png)

**Step 2: Add Files**
*   Add `RTL/my_multi_calc.v` and run Analyze Synthesis Files.
    ![Files Tab Settings](./images/image_files.png)

**Step 3 & 4: Interface and Timing Settings**
*   **Interface Type**: Select **Custom Instruction Slave**.
*   **Timing**: Explicitly set **Multicycle** (2 or 3 cycles) considering the pipeline depth. Combinatorial should not be used.
    *   *Note: Since the hardware logic is 2 steps, 2 or 3 is appropriate.*

*(Please refer to the setting on the right side of the image below)*

![Signal and Parameter Settings](./images/image_signals.png)

**Step 5: Completion**
1.  Click **Finish** to save the component (`cust_cal`).
2.  Add the new component to the Qsys system.

---

## Chapter 4: High-speed Data Movement (DMA)

### Bottleneck: CPU Copy
Although the Nios II processor is versatile, using it to copy large capacity buffer data (e.g., from main memory to hardware accelerator) is inefficient. It consumes CPU cycles for every single `ldw` / `stw` instruction and causes a bottleneck.

### Solution: Scatter-Gather DMA (SG-DMA)
To solve this, we integrated an **Altera Scatter-Gather DMA Controller** into the Qsys system. Through this, we let the hardware independently handle large capacity data transfers so that the CPU can perform other tasks.

### Architecture and Data Flow
This system is designed to seamlessly move processing data:

1.  **Source (On-Chip Memory)**:
    *   Holds raw input data (e.g., array of operands for calculation).
    *   Mapped as a slave in Qsys.
2.  **Transfer Engine (SG-DMA)**:
    *   Operates in **Memory-to-Memory** mode.
    *   Reads from On-Chip Memory and writes to the custom slave.
    *   Supports "Scatter-Gather" through descriptors, so it can process non-continuous memory blocks at once if necessary.
3.  **Destination (Custom Slave / DPRAM)**:
    *   Receives data stream through the Avalon-MM Slave interface.
    *   Stores it in internal DPRAM so that custom logic or other masters can access it.

![Qsys System Integration](./images/image_qsys.png)
*(Figure: Qsys system view showing connections between Nios II, On-Chip Memory, SG-DMA, and custom slave)*

### Evolution: Toward Modular SGDMA
Beyond simple memory copying, to perform calculations **during** data movement (`(Data * A) / 400`), a single existing Memory-to-Memory DMA is not enough. This is because we need to insert our `stream_processor` in the middle of the data stream.

For this, we introduced the **Modular SGDMA** architecture. This method enables flexible connection by functional separation (Disaggregate) of the DMA.

#### Architecture Changes
*   **Existing (Standard SGDMA)**: `Read Master` and `Write Master` are tied inside. (For simple copy purposes)
*   **New (Modular SGDMA)**: Separated into three independent components.
    1.  **mSGDMA Dispatcher**: Receives commands (Descriptor) from Nios II and controls Read/Write Master.
    2.  **mSGDMA Read Master**: Reads data from memory and sends it to **Avalon-ST Source**.
    3.  **mSGDMA Write Master**: Receives data with **Avalon-ST Sink** and writes to memory.

#### Platform Designer Implementation Guide
We completed the streaming pipeline by configuring it in Platform Designer (Qsys) as follows:

1.  **Add Components**:
    *   `Modular SGDMA Dispatcher`: Connect the CSR interface to the Nios II data master.
    *   `Modular SGDMA Read Master`: Connect the memory map master to source memory, and the streaming source (`Data Source`) to the processor.
    *   `Modular SGDMA Write Master`: Connect the memory map master to destination memory, and the streaming sink (`Data Sink`) to the processor.
2.  **Stream Processor Connection (Core)**:
    *   `Read Master.Source` Connects to `Stream Processor.Sink`
    *   `Stream Processor.Source` Connects to `Write Master.Sink`
    *   By doing this, data read from memory must inevitably pass through our hardware logic before it can be written back to memory.

### Streaming Pipeline Control (Valid-Ready Handshake)
The core of the **Stream Processor** (`stream_processor.v`) design using the Avalon-Streaming interface is flow control (Backpressure).

Even if the pipeline stage gets longer, whether to transfer data in each step (`enable`) follows a simple and powerful rule determined by a combination of the following three factors:

1.  **Current Valid (`s1_valid`)**: Do I have data?
2.  **Next Valid (`s2_valid`)**: Is the next step full?
3.  **Output Ready (`aso_ready`)**: Can the final output go out?

#### Pipeline Control Logic (Backpressure Chain)
Looking specifically at how the `Ready` signal is connected like a chain from back to front in the actual 3-stage pipeline (Stage 0, 1, 2) is as follows.

```verilog
// 1. Ready state of Stage 2 (last stage):
// "When there is no data" OR "When it can be taken from the next stage (mSGDMA)"
assign pipe_ready[2] = (!pipe_valid[2]) || aso_ready;

// 2. Ready state of Stage 1 (middle stage):
// "When there is no data" OR "When the next stage (Stage 2) is empty or ready to take"
assign pipe_ready[1] = (!pipe_valid[1]) || pipe_ready[2];

// 3. Ready state of Stage 0 (first stage):
// "When there is no data" OR "When the next stage (Stage 1) is empty or ready to take"
assign pipe_ready[0] = (!pipe_valid[0]) || pipe_ready[1];

// Finally, notify the very front end (Sink)
assign asi_ready = pipe_ready[0];
```

This expression handles all of the following scenarios:

| Scenario | State Description | Action (`Ready`) | Result |
| :--- | :--- | :--- | :--- |
| **1. Empty state** | `pipe_valid[i]=0` | **Ready** | Since it is an empty seat, it immediately receives data from the previous stage. |
| **2. Flowing state** | `pipe_valid[i]=1`, `pipe_valid[i+1]=0` | **Ready** | Since current data can be pushed to the next cell, it receives new data. |
| **3. Full state** | All `pipe_valid=1` | Depends on `aso_ready` | If output goes out (`aso_ready=1`), everything moves by one cell like dominoes. If output is blocked, everything Stalls. |

This structure can be expanded with the same rules no matter how many pipeline stages increase, and it is an **industry-standard handshake** method that guarantees accurate data flow without a FIFO.

---

## Chapter 5: Embedded Software Implementation
Hardware can only be as good as the software that drives it. We implemented a C application (`main.c`) to control the DMA and benchmark the performance of the custom accelerator.

### 1. How-To: Address Handling and Register Access (Address Handling)
Before moving on to complex DMA, it is essential to understand how the C code "talks" with our custom slave hardware.

#### Step A: System Map (`system.h`)
When you compile hardware in Qsys and generate a BSP (Board Support Package), Quartus generates a `system.h` file. This file contains the base addresses of all modules.
*   **Target**: `MMIO_0_BASE` (The base address of our "my_custom_slave" component).

#### Step B: Read/Write Macros (`io.h`)
To access hardware registers, you must use specific macros provided by the Altera HAL. Choosing the wrong macro can cause segmentation faults or alignment errors.

| Macro | Argument | Description | Addressing Mode |
| :--- | :--- | :--- | :--- |
| **`IOWR`** | `(BASE, REG_NUM, DATA)` | Writes 32-bit data to the register. | **Word offset** (`BASE + REG_NUM * 4`) |
| **`IORD`** | `(BASE, REG_NUM)` | Reads 32-bit data from the register. | **Word offset** (`BASE + REG_NUM * 4`) |
| `IOWR_32DIRECT` | `(BASE, OFFSET, DATA)` | Writes 32-bit data to a specific *byte* address. | **Byte offset** (`BASE + OFFSET`) |
| `IORD_32DIRECT` | `(BASE, OFFSET)` | Reads 32-bit data from a specific *byte* address. | **Byte offset** (`BASE + OFFSET`) |
| `IOWR_16DIRECT` | `(BASE, OFFSET, DATA)` | Writes 16-bit data. | **Byte offset** (`BASE + OFFSET`) |
| `IOWR_8DIRECT` | `(BASE, OFFSET, DATA)` | Writes 8-bit data. | **Byte offset** (`BASE + OFFSET`) |

**`IOWR` vs `IOWR_32DIRECT` Which one should be used?**
*   **Use `IOWR`** (Recommended): When the component uses slave address alignment in "Word" units like our project. If you pass the *index* (0, 1, 2...), the macro automatically multiplies by 4.
*   **Use `IOWR_32DIRECT`**: Used when accessing Raw memory or when access to a component using "Byte" address alignment where the byte address (e.g., `0`, `4`, `8`...) must be explicitly controlled.

#### Step C: The "Magic" of Indexing
Because the hardware is set to **Word Alignment**, the index `i` of the Nios II software perfectly matches the `i`-th row of the DPRAM.
1.  **Software**: `IOWR(MMIO_0_BASE, 5, val)` -> CPU outputs byte address `Base + 20` (0x14).
2.  **Interconnect**: Detects that it is a "Word Aligned" slave and shifts the address. `20 >> 2` = `5`.
3.  **Hardware**: The slave receives address `5`. DPRAM writes data to the 5th slot.

**Code Example (`main.c`):**
```c
#include "io.h"
#include "system.h"

// Simple R/W Test
for (int i = 0; i != 256; ++i) {
    // Write: index 'i' is mapped 1:1 with DPRAM address 'i'
    IOWR(MMIO_0_BASE, i, 0x1000 + i); 
}

for (int i = 0; i != 256; ++i) {
    // Read: data verification
    int read_val = IORD(MMIO_0_BASE, i);
    // ...
}
```

### 2. DMA Control: Skipping cache
A trap commonly experienced in Nios II DMA systems is the **Data Cache Coherency** problem. The CPU has a data cache, but the DMA engine directly reads physical memory (RAM).
If we write data as `src_data[i] = ...` and start DMA immediately, the data may still stay inside the CPU cache instead of RAM. Then DMA will copy the previous garbage value in RAM.
**Solution:** Before starting the transfer, the data cache must be explicitly flushed to be written into RAM.

```c
#include <sys/alt_cache.h> 

void start_dma_transfer() {
    // 1. Data preparation
    for(int i=0; i<256; i++) src_data[i] = i * 400;

    // [Essential] Flush the cache to RAM so that DMA sees correct data
    alt_dcache_flush(src_data, sizeof(src_data));

    alt_msgdma_dev *dma_dev = alt_msgdma_open(DMA_ONCHIP_DP_CSR_NAME);

    // 2. Create Descriptor
    alt_msgdma_standard_descriptor descriptor;
    alt_msgdma_construct_standard_mm_to_mm_descriptor(
        dma_dev,
        &descriptor,
        (alt_u32 *)src_data,        // Source (Array in RAM)
        (alt_u32 *)MMIO_0_BASE,     // Destination (Custom slave base address)
        sizeof(src_data),           // Length
        0
    );

    // 3. Start DMA (Async)
    alt_msgdma_standard_descriptor_async_transfer(dma_dev, &descriptor);
}
```

### 3. Benchmarking: Hardware vs. Software
To prove the value of custom instructions, we measured the execution time of the hardware accelerator and pure software implementation using a high-resolution timestamp timer.

**Measurement Code:**
```c
#include "system.h"
#include "sys/alt_timestamp.h"

// ... inside main() ...

  if (alt_timestamp_start() < 0) {
      printf("Error: Timestamp timer not defined in BSP.\n");
      return -1;
  }

  // Hardware Measurement (Custom Instruction)
  time_start = alt_timestamp();
  for (int i = 990; i != 1024; ++i) {
      for (int j = 390; j != 400; ++j) {
          // New instruction: Multi-cycle multiplication & division
          result = (int)ALT_CI_CUST_CAL_0(i, j); 
          sum += result;
      }
  }
  time_hw = alt_timestamp() - time_start;
  
  // Software Measurement (Standard Operators)
  time_start = alt_timestamp();
  for (int i = 990; i != 1024; ++i) {
      for (int j = 390; j != 400; ++j) {
          result = i * j / 400; // Software division is slow
          sum += result;
      }
  }
  time_sw = alt_timestamp() - time_start;

  printf("HW Cycles: %llu\n", time_hw);
  printf("SW Cycles: %llu\n", time_sw);
  if (time_sw > 0) {
      printf("Speedup: %.2fx faster!\n", (float)time_sw / (float)time_hw);
  }
```

This setup provides solid data on the speed improvement that can be obtained by moving heavy arithmetic operations to logic.

### 5. Performance Results
Results of performing tests on actual hardware are as follows:

![Nios II Performance Measurement Result](./images/image_nios_result.png)
*(Figure: Nios II console output screen - You can see that HW Cycles are significantly less than SW Cycles)*

As you can see in the above result image, the hardware operation (HW Cycles) using Custom Instruction spent much fewer cycles than the software operation (SW Cycles) for the same operation, which proved a certain acceleration effect.



---

## Chapter 6: Modular SGDMA Troubleshooting and Lessons Learned
The actual implementation process of **Modular SGDMA**, which inserts operation logic in the middle of the data stream beyond simple DMA copying, was not as smooth as the theory. We summarize the "struggling" parts encountered during the development process and the lessons learned accordingly.

### 1. Limits of HAL Driver: `NULL` Device Pointer
*   **Problem**: The standard `alt_msgdma_open()` command kept returning `NULL`.
*   **Cause**: The `altera_msgdma` HAL driver provided by Intel expects a "Standard mSGDMA" configuration where **Dispatcher + Read Master + Write Master** are tied as one complete package. However, since we untied and connected each as independent components to insert operation logic, the software failed to recognize it as one integrated DMA device.
*   **Solution**: We boldly gave up calling high-level HAL APIs and chose a method to directly fire commands to the **CSR (Control Status Register)** of the Dispatcher using `IOWR` macros. The interface became a bit rough, but we were able to perfectly control the hardware.

### 2. Trap of Qsys Settings: Operating Mode (Mode)
*   **Problem**: DMA transfer appeared as completed (`BUSY=0`), but the result memory was still `0` (`Act=0`) or previous data remained.
*   **Cause**: The operation mode of the Read/Write Dispatcher was maintained as the default, **`Memory-to-Memory`**.
*   **Lesson**: In a separated architecture, **Read Master must be explicitly set to `Memory-to-Stream`**, and **Write Master to `Stream-to-Memory`** mode. If the mode is wrong, the data stream handshake does not occur normally and the pipeline stops.

### 3. Uncertainty of Verilog Synthesis: Array vs. Explicit Register
*   **Problem**: In `stream_processor.v` where the operation logic is located, a phenomenon where the division stage was altogether ignored (Bypass) occurred.
*   **Cause**: We used an **array form** like `reg [63:0] stage_data[0:1]` when implementing the pipeline stage, but in certain synthesis tool versions, array-based control logic is unintentionally optimized or connections are missing.
*   **Solution**: Rewrote the logic with **individual registers with clear names** like `s0_data`, `s1_data`. Through this, we ensured the reliability of the operation by letting the synthesizer clearly distinguish each stage of the pipeline physically.

### 4. Hardware "Freeze" Prevention: Software Reset
*   **Problem**: During testing, if an error occurred or forced termination was made, the DMA often did not respond in the next execution.
*   **Solution**: Added a **Dispatcher software reset** sequence at the beginning of the `main.c` test function.
    ```c
    // Reset Dispatcher to a clean state
    IOWR_ALTERA_MSGDMA_CSR_CONTROL(BASE, ALTERA_MSGDMA_CSR_RESET_MASK);
    while (IORD_ALTERA_MSGDMA_CSR_STATUS(BASE) & ALTERA_MSGDMA_CSR_RESET_STATE_MASK);
    ```
    We confirmed again that making hardware always in a "predictable state" software-wise is the core of embedded programming.

### 5. Precision and Error: Margin of 0.1%
*   **Challenge**: A minute Rounding difference can occur between the integer operation accelerator (`Shift-Add`) and the CPU's floating-point division result.
*   **Solution**: In verification code, instead of `actual != expected`, we introduced the **Tolerance (allowable error)** concept like `abs(actual - expected) <= 1`. We learned that when designing hardware, it is as important to define the 'allowable range' as much as the 'perfection' of the result.

### 6. Trap of Endianness: "First Symbol In High-Order Bits" ***Attention***

> [!WARNING]
> **★★★★★ Very Important: Read if you don't want to see the magic of data being mixed! ★★★★★**

*   **Symptom**:
    *   Input data `0x00000190` (400) was put in, but it was recognized in hardware as byte-reversed like `0x90010000`.
    *   It is normal in Bypass mode, but a nonsensically large value comes out after going through the operation.
*   **Cause**:
    *   Because the **"First Symbol In High-Order Bits"** option was on in the Avalon-ST Sink settings of Qsys (Platform Designer).
    *   **Nios II (Little-Endian)**: The first byte must come to the lowest seat (LSB).
    *   **Option On (Big-Endian)**: Sends the first byte to the highest seat (MSB).
    
    ![Endianness Setting Warning](./images/image_endian.png)
    *(Figure: First Symbol In High-Order Bits setting of Avalon-ST Sink)*
*   **Solution**:
    *   If possible, **uncheck the corresponding checkbox (Uncheck)** in the Avalon-ST Sink settings.
    *   **Caution**: In cases like mSGDMA where the **option is fixed (Grayed out)** and cannot be turned off, a measure of **manually reversing the byte order (Byte Swap)** at the hardware (RTL) input/output stage is necessary.
    *   `last_asi_data <= {asi_data[7:0], asi_data[15:8], ...}`
    *   **Result**: Confirmed normal output of `(400 * 800) / 400 = 800` after RTL modification!
    *   **Bypass mode performance**: **7.59x faster** than CPU.
    *   **Operation mode performance**: **86.14x faster** than CPU! (Division operation included)

---

## Appendix: Fixed-Point Arithmetic Deep Dive
The mathematical background of the **"Shift-Add"** method we used to implement division `/ 400` is **Fixed-Point Arithmetic**.

To process a real number (decimal) $F$ in hardware where only integer arithmetic is possible, the formula for finding the closest integer coefficient $K$ and shift bit number $Q$ is as follows.

### **The Formula**

$$ K = \text{Round}(F \times 2^Q) $$

*   $F$: Goal real number to express (in our case $1/400 = 0.0025$)
*   $Q$: Number of bits to express below the decimal point (Q-Factor). Precision increases as it gets larger, but bit width increases.
*   $K$: Integer coefficient to actually multiply in hardware.

### **Application Example ($F = 1/400$)**
We chose $Q=21$ for even higher precision.

$$ K = 0.0025 \times 2^{21} = 0.0025 \times 2097152 = 5242.88 $$

Rounding this value gives **$K = 5243$**.
Therefore, we calculate in hardware as follows:

$$ \text{Result} = (\text{Input} \times \text{Coeff} \times 5243) \gg 21 $$

At this time, the value actually multiplied is $5243 / 2^{21} \approx 0.00249995$, and the error from the original goal of $0.0025$ is **about 0.0018%**, which is very precise. This is the magic of fixed-point arithmetic.

---

## Chapter 5: Evolution to N-Stage Pipeline
As the final step of the project, we refactored the pipeline, which was composed of 1 stage, into an extensible **N-Stage Pipeline** structure.

### **1. Why N-Stage Structure?**
*   **Securing Timing Margin**: If all operations (endian conversion, large multiplication, shift) are gathered in one cycle, the probability of an error occurring when the clock frequency gets high is large. We secured margin by dividing this into 3 stages.
*   **Backpressure Processing**: We implemented the **Valid-Ready Handshake** according to the rule so that data is not lost when the rear mSGDMA stops, by stopping in turn.

### **2. 3-Stage Pipeline Configuration**
*   **Stage 0**: Input data capture and preprocessing (Byte Swap).
*   **Stage 1**: Coefficient multiplication operation (`Input * Coeff`).
*   **Stage 2**: Reciprocal multiplication (`* 5243`) and shift (`>> 21`), and final endian restoration.

This structure is an **industrial-level RTL design** method that can operate stably even at higher clock speeds while maintaining data throughput.

---

## Closing
Through this project, we confirmed how powerful performance (86x speedup) can be achieved when **Custom Instruction**, **mSGDMA**, and **RTL Optimization** are combined.

Particularly beyond simply "working code," it is very meaningful in that we squarely broke through key challenges encountered in practical FPGA design, such as **resolving endianness problems**, **fixed-point operation optimization**, and **N-stage pipeline design**.

We hope this record will be a good guidebook for my future self or other colleagues who will maintain this system.
