# Future Roadmap: Verilog Mastery for SW Experts

This document outlines the next steps for transitioning from a Software Expert to a Verilog/SoC Design Expert.

## 1. Advanced Verification (Cocotb)
Transition from traditional testbenches to Python-based modern verification environment.

- [x] **Avalon Interface Verification (cocotbext-avalon)**
    - [x] Prepare initial Cocotb test environment in `tests/cocotb`.
    - [x] Integrate with **Pytest** for professional SW-style testing.
        - [x] Run `pip install cocotb-test` in WSL.
        - [x] Execute `pytest test_runner.py` to run all module tests at once.
    - [x] **Waveform Viewing**:
        - [x] Enabled `waves=True` in `test_runner.py`.
        - [x] View generated `.vcd` or `.fst` files in `sim_build/` using **GTKWave**.
        - [x] Run `make pytest_clean` to remove simulation artifacts and XML logs.
    - [x] Create a Unit Test environment for `stream_processor.v` using Python Mock Drivers/Monitors.
    - [ ] Implement randomized stress tests for Backpressure logic (Partially covered in `tb_stream_processor_avs.py`).
- [ ] **AXI Interface Verification (cocotbext-axi)**
    - [ ] Study AMBA AXI4 Protocol (AXI-Stream, AXI-Lite).
    - [ ] Implement a simple AXI-Stream module.
    - [ ] Verify AXI-Stream logic using `cocotbext-axi`.
    - [ ] Explore AXI RAM models in Cocotb for Memory-Mapped logic verification.

## 2. Advanced Hardware Acceleration (SIMD)
Build high-performance compute engines using parallel processing techniques.

- [x] **Stream Processor & DMA Optimization**
    - [x] Implement 3-Stage Pipeline with Backpressure.
    - [x] Solve Endianness issues (Re-ordering 128-bit packed data).
    - [x] **128-bit SIMD Implementation**: 4-Lane Parallel Processing.
    - [x] **Burst Master Evolution (BM1-BM4)**:
        - [x] **BM1**: Basic Burst Copy (Avalon-MM Master with FIFO buffering).
        - [x] **BM2**: Performance Optimization (**Back-to-Back Burst**, Pipelined Read).
        - [x] **BM3**: Data Processing Pipeline (**Two-FIFO** architecture, Multiplication logic).
        - [x] **BM4**: Robust Flow Control (**Valid-Ready Handshake**, Division Approximation).
        - [x] Update Cocotb test suite for arithmetic verification and robust build management.
    - [x] Achieve >85x Speedup vs Software.

- [x] **Documentation & Project Structure**
    - [x] Centralize all documentation and images into the `doc/` directory.
    - [x] Implement 2-way navigation links between all `.md` files for a "Technical Blog" experience.
    - [x] Segregate Nios II/HPS specific details into `doc/nios.md`.

## 3. Image Processing Hardware
Apply pipeline and DMA knowledge to real-time pixel processing.

- [ ] **Basic Pixel Filter Implementation**
    - [ ] Design a Grayscale conversion module (weighted sum of R, G, B).
    - [ ] Implement a simple 3x3 Convolution engine (e.g., Sobel edge detection).
- [ ] **Streaming Image Pipeline**
    - [ ] Integrate image filters into the 3-Stage pipeline structure.
    - [ ] Handle line buffers (FIFO) for 2D kernel operations.
    - [ ] Benchmark 86x speedup vs. SW OpenCV implementation.

## 4. High-Speed Signal Processing (HDMI & LVDS)
Understand the physical layer and timing requirements of video signals.

- [ ] **HDMI Output (DE10-Nano Specific)**
    - [ ] **I2C Controller for ADV7513**
        - [ ] Study ADV7513 Programming Guide (Register Map).
        - [ ] Implement I2C Master (or use OpenCore/Intel IP) to configure the HDMI transmitter chip.
        - [ ] Verify I2C communication (ACK/NACK).
    - [ ] **Video Sync Generator (VGA Timing)**
        - [ ] Generate H-Sync, V-Sync, and Data Enable (DE) signals for 640x480 resolution (25.175MHz Pixel Clock).
        - [ ] Verify timing using simulation (GTKWave).
    - [ ] **Video Pattern Generator (VPG)**
        - [ ] Design a simple Color Bar pattern generator based on X/Y coordinates.
    - [ ] **Top-Level Integration**
        - [ ] Connect PLL (Clock Wizard) for requested Pixel Clock.
        - [ ] Map I/O pins (HDMI_TX_D, HDMI_TX_CLK, etc.) in Quartus Pin Planner.
- [ ] **Advanced: HDMI Input & Image Pipeline**
    - [ ] Understand HDMI RX constraints.
    - [ ] Implement Frame Buffer using DDR3 Memory (requires Video DMA).

## 4. High-Speed Signal Processing (LVDS & SerDes)

## 5. Architectural Deep Dive
- [ ] **RISC-V Core Implementation**: Design a basic 3-stage RISC-V CPU to understand instruction pipelines.
- [ ] **System-on-Chip (SoC) Integration**: Build a custom SoC by hand-typing AXI interconnects instead of using Qsys/Vivado IP Integrator.

---
*Roadmap goal: Become a Full-Stack SoC Engineer who can bridge the gap between High-Level Software and Gate-Level Hardware.*
