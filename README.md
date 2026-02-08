# Nios II Custom Instruction & DMA Acceleration Project

This project demonstrates the performance optimization of an FPGA-based Nios II system using **Custom Instructions** and **Scatter-Gather DMA (SG-DMA)**.

It implements a hardware-accelerated arithmetic unit for high-speed calculation and uses DMA for efficient memory-to-memory data transfer, offloading tasks from the CPU.

## Design Journey (Documentation)
For a deep dive into the implementation details, including design rationale, timing analysis, and pipeline logic, please refer to the history documents:
*   [🇺🇸 **English: Implementation Journey**](./history.md)
*   [🇰🇷 **Korean: FPGA 프로젝트 검증 (한글)**](./history_kor.md)

### Read this in other languages
*   [🇰🇷 **한국어 (Korean)**](./README_kor.md)

## Project Overview

### Key Features
1.  **Custom Instruction Unit**:
    *   Optimized hardware logic for specific arithmetic (`(A * B) / 400`).
    *   **Timing Optimization**: Replaces slow hardware division with shift-add operations (`(A * 5243) >> 21`) to resolve Setup Time Violations.
    *   Achieves significant cycle reduction compared to software implementation.

2.  **Streaming Acceleration (Stream Processor)**:
    *   **N-Stage Pipeline**: Refactored to a parameterizable 3-stage architecture for high-frequency stability.
    *   **Backpressure support**: Implemented robust Avalon-ST Valid-Ready handshake (`pipe_valid`/`pipe_ready` chain).
    *   **Endianness Correction**: Automatic byte-swapping to match Nios II memory layout.
    *   **Reusable Template**: Includes [pipe_template.v](./RTL/pipe_template.v) for future projects.

3.  **Modular SGDMA Integration**:
    *   Offloads CPU by performing calculations inline during DMA transfers.
    *   Uses disaggregated mSGDMA Dispatcher, Read Master, and Write Master.

## Directory Structure

```text
c:/Workspace/quartus_project/
├── RTL/                    # Verilog HDL Source Files
│   ├── stream_processor.v  # 3-Stage Pipeline Accelerator
│   ├── pipe_template.v     # Reusable N-Stage Template
│   ├── my_multi_calc.v     # Custom Instruction Logic
│   └── top_module.v        # Top-level integration
├── software/
│   ├── cust_inst_app/      # Nios II Application Code
│   │   └── main.c          # Benchmarking & Test App (HW v0x110)
│   └── cust_inst/          # BSP - *Excluded from git*
├── history_kor.md          # Implementation Journey (Korean)
├── history.md              # Implementation Journey (English)
└── custom_inst_qsys.qsys   # Platform Designer System File
```

## Performance Results

Our final benchmarks on Nios II (50MHz) demonstrate massive acceleration:

- **Bypass Mode**: 7.59x faster than CPU memory copy.
- **Arithmetic Acceleration**: **86.14x faster** than pure software division.

---

## License
MIT License
