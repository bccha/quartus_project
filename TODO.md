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
        - [ ] View generated `.vcd` or `.fst` files in `sim_build/` using **GTKWave**.
    - [ ] Create a Unit Test environment for `stream_processor.v` using Python Mock Drivers/Monitors.
    - [ ] Implement randomized stress tests for Backpressure logic.
- [ ] **AXI Interface Verification (cocotbext-axi)**
    - [ ] Study AMBA AXI4 Protocol (AXI-Stream, AXI-Lite).
    - [ ] Implement a simple AXI-Stream module.
    - [ ] Verify AXI-Stream logic using `cocotbext-axi`.
    - [ ] Explore AXI RAM models in Cocotb for Memory-Mapped logic verification.

## 2. Image Processing Hardware
Apply pipeline and DMA knowledge to real-time pixel processing.

- [ ] **Basic Pixel Filter Implementation**
    - [ ] Design a Grayscale conversion module (weighted sum of R, G, B).
    - [ ] Implement a simple 3x3 Convolution engine (e.g., Sobel edge detection).
- [ ] **Streaming Image Pipeline**
    - [ ] Integrate image filters into the 3-Stage pipeline structure.
    - [ ] Handle line buffers (FIFO) for 2D kernel operations.
    - [ ] Benchmark 86x speedup vs. SW OpenCV implementation.

## 3. High-Speed Signal Processing (HDMI & LVDS)
Understand the physical layer and timing requirements of video signals.

- [ ] **HDMI (TMDS) Signal Handling**
    - [ ] Study HDMI 1.4 protocol and TMDS encoding (8b/10b).
    - [ ] Implement/Analyze a Video Pattern Generator (VPG).
    - [ ] Understand H-Sync, V-Sync, and Data Enable (DE) timing.
- [ ] **LVDS (Low-Voltage Differential Signaling)**
    - [ ] Learn Differential Signaling principles.
    - [ ] Implement Serialization/Deserialization (SerDes) for LVDS.
    - [ ] Handle Clock Domain Crossing (CDC) between pixel clock and serial clock.

## 4. Architectural Deep Dive
- [ ] **RISC-V Core Implementation**: Design a basic 3-stage RISC-V CPU to understand instruction pipelines.
- [ ] **System-on-Chip (SoC) Integration**: Build a custom SoC by hand-typing AXI interconnects instead of using Qsys/Vivado IP Integrator.

---
*Roadmap goal: Become a Full-Stack SoC Engineer who can bridge the gap between High-Level Software and Gate-Level Hardware.*
