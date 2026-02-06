# FPGA Project Verification: From Custom Slave to Hardware Acceleration

**Date:** 2026-02-06
**Project Path:** `d:/quartus_project`

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

## Chapter 3: System Integration

### Top-Level Wiring
Finally, these modules are brought together in the top-level entity. The `custom_inst_qsys` (generated by Platform Designer) acts as the brain, while our custom HDL modules provide the muscle.

**Key Integration (`RTL/top_module.v`):**
```verilog
    // Instantiating the Qsys System
	custom_inst_qsys u0 (
		.clk_clk       (CLOCK_50),
		.reset_reset_n (RST),  
        // ... connecting Avalon-MM signals ...
		.mmio_exp_readdata      (w_readdata),
		.mmio_exp_readdatavalid (w_readdatavalid), // Connected to our slave
        // ...
	);

    // Instantiating the Custom Slave
	my_custom_slave s1 (
		.clk(CLOCK_50),
		.readdata(w_readdata), // Feeding back to Qsys
		.readdatavalid(w_readdatavalid)
        // ...
	);
```

---

## Appendix: Platform Designer Setup Guide

To integrate the accelerator (`my_multi_calc.v`) into the Nios II system, follow these steps in Platform Designer.

**Step 1: New Component**
*   Create a new component and verify the block symbol.
    ![Block Symbol](./images/image_block.png)

**Step 2: Add Files**
*   Add `RTL/my_multi_calc.v` and analyze synthesis files.
    ![Files Tab](./images/image_files.png)

**Step 3 & 4: Interface & Timing Configuration**
*   **Interface Type**: Select **Custom Instruction Slave**.
*   **Timing**: Set explicit **Multicycle** timing (2 or 3 cycles) to account for our pipeline depth. Do not use Combinatorial.
    *   *Note: The hardware logic is 2 cycles deep, so 2 or 3 is appropriate.*

*(Refer to the settings on the right side of the image below)*

![Signals & Parameters Configuration](./images/image_signals.png)

### Step 5: Finish
1.  Click **Finish** to save the component (`cust_cal`).
2.  Add the new component to your Qsys system.

---

## Chapter 4: High-Speed Data Movement (DMA)

### The Bottleneck: CPU Copy
While the Nios II processor is versatile, using it to copy large buffers of data (e.g., from main memory to our hardware accelerator) is inefficient. It consumes CPU cycles for every single load and store instruction (`ldw` / `stw`), creating a bottleneck.

### The Solution: Scatter-Gather DMA (SG-DMA)
To solve this, we integrated an **Altera Scatter-Gather DMA Controller** into the Qsys system. This allows the hardware to handle bulk data transfers independently, freeing the CPU for other tasks.

### Architecture & Data Flow
The system is designed to move processing data seamlessly:

1.  **Source (On-Chip Memory)**:
    *   Holds the raw input data (e.g., arrays of operands for calculation).
    *   Mapped as a slave in Qsys.
2.  **Transfer Engine (SG-DMA)**:
    *   **Memory-to-Memory** mode.
    *   Reads from On-Chip Memory and writes to the Custom Slave.
    *   Supports "Scatter-Gather" via descriptors, meaning it can process non-contiguous memory blocks in a single run if needed.
3.  **Destination (Custom Slave / DPRAM)**:
    *   Receives the data stream via its Avalon-MM Slave interface.
    *   Stores it in the internal DPRAM, ready for the custom logic or another master to access.

![Qsys System Integration](./images/image_qsys.png)
*(Figure: Qsys System View showing Nios II, On-Chip Memory, SG-DMA, and Custom Slave connectivity)*

---

## Chapter 5: Embedded Software Implementation

The hardware is only as good as the software that drives it. We implemented a C application (`main.c`) to control the DMA and benchmark our custom accelerator.

### 1. How-To: Address Handling & Register Access
Before diving into complex DMA, it is essential to understand how the C code talks to our Custom Slave hardware.

#### Step A: System Map (`system.h`)
When we compile the hardware in Qsys and generate the BSP (Board Support Package), Quartus creates a file called `system.h`. This file contains the base addresses of all modules.
*   **Target**: `MMIO_0_BASE` (The base address of our "my_custom_slave" component).

#### Step B: Read/Write Macros (`io.h`)
Accessing hardware registers requires specific macros provided by the Altera HAL. It's crucial to choose the right one to avoid segmentation faults or misalignment.

| Macro | Arguments | Description | Addressing Mode |
| :--- | :--- | :--- | :--- |
| **`IOWR`** | `(BASE, REG_NUM, DATA)` | Writes 32-bit data to a register. | **Word Offset** (`BASE + REG_NUM * 4`) |
| **`IORD`** | `(BASE, REG_NUM)` | Reads 32-bit data from a register. | **Word Offset** (`BASE + REG_NUM * 4`) |
| `IOWR_32DIRECT` | `(BASE, OFFSET, DATA)` | Writes 32-bit data to a specific *byte* address. | **Byte Offset** (`BASE + OFFSET`) |
| `IORD_32DIRECT` | `(BASE, OFFSET)` | Reads 32-bit data from a specific *byte* address. | **Byte Offset** (`BASE + OFFSET`) |
| `IOWR_16DIRECT` | `(BASE, OFFSET, DATA)` | Writes 16-bit data. | **Byte Offset** (`BASE + OFFSET`) |
| `IOWR_8DIRECT` | `(BASE, OFFSET, DATA)` | Writes 8-bit data. | **Byte Offset** (`BASE + OFFSET`) |

**Why use `IOWR` vs `IOWR_32DIRECT`?**
*   **Use `IOWR`** (Recommended): When your component is defined as a slave with "Word" address alignment (like our project). You pass the *index* (0, 1, 2...), and the macro automatically multiplies by 4.
*   **Use `IOWR_32DIRECT`**: When accessing raw memory or a component with "Byte" address alignment where you need explicit control over the byte address (e.g., `0`, `4`, `8`...).

#### Step C: The "Magic" of Indexing
Because our hardware is configured for **Word Alignment**, the Nios II software's index `i` matches the DPRAM's row `i` perfectly.
1.  **Software**: `IOWR(MMIO_0_BASE, 5, val)` -> CPU outputs byte address `Base + 20` (0x14).
2.  **Interconnect**: Detects "Word Aligned" slave. Shifts address `20 >> 2` = `5`.
3.  **Hardware**: Slave receives address `5`. DPRAM writes to the 5th slot.

**Code Example (`main.c`):**
```c
#include "io.h"
#include "system.h"

// Simple R/W Test
for (int i = 0; i != 256; ++i) {
    // Write: Index 'i' maps directly to DPRAM address 'i'
    IOWR(MMIO_0_BASE, i, 0x1000 + i); 
}

for (int i = 0; i != 256; ++i) {
    // Read: Verify the data
    int read_val = IORD(MMIO_0_BASE, i);
    // ...
}
```

### 2. DMA Control: Skipping the Cache
A common pitfall in Nios II DMA systems is **Data Cache Coherency**. The CPU has a data cache, but the DMA engine reads directly from physical memory.
If we write data `src_data[i] = ...` and immediately start DMA, the data might still be sitting in the CPU's cache, not in RAM. The DMA would then copy old garbage data.
**Fix:** We must explicitly flush the data cache before starting the transfer.

```c
#include <sys/alt_cache.h> 

void start_dma_transfer() {
    // 1. Prepare Data
    for(int i=0; i<256; i++) src_data[i] = i * 400;

    // [CRITICAL] Flush Cache to RAM so DMA sees the correct data
    alt_dcache_flush(src_data, sizeof(src_data));

    alt_msgdma_dev *dma_dev = alt_msgdma_open(DMA_ONCHIP_DP_CSR_NAME);

    // 2. Create Descriptor
    alt_msgdma_standard_descriptor descriptor;
    alt_msgdma_construct_standard_mm_to_mm_descriptor(
        dma_dev,
        &descriptor,
        (alt_u32 *)src_data,        // Source (Array in RAM)
        (alt_u32 *)MMIO_0_BASE,     // Destination (Custom Slave Base Address)
        sizeof(src_data),           // Length
        0
    );

    // 3. Launch DMA (Async)
    alt_msgdma_standard_descriptor_async_transfer(dma_dev, &descriptor);
}
```

### 2. Benchmarking: Hardware vs. Software
To prove the value of our Custom Instruction, we measured the execution time of our hardware accelerator against a pure software implementation using the high-resolution timestamp timer.

**Measurement Code:**
```c
#include "system.h"
#include "sys/alt_timestamp.h"

// ... inside main() ...

  if (alt_timestamp_start() < 0) {
      printf("Error: Timestamp timer not defined in BSP.\n");
      return -1;
  }

  // Measure Hardware (Custom Instruction)
  time_start = alt_timestamp();
  for (int i = 990; i != 1024; ++i) {
      for (int j = 390; j != 400; ++j) {
          // New Instruction: Multi-cycle multiplication & division
          result = (int)ALT_CI_CUST_CAL_0(i, j); 
          sum += result;
      }
  }
  time_hw = alt_timestamp() - time_start;
  
  // Measure Software (Standard Operators)
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

This setup gives us concrete data on the speedup achieved by moving the heavy arithmetic to logic.

