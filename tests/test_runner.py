import os
import sys
from cocotb_test.simulator import run

def test_burst_master():
    # Calculate absolute path to project root (parent of 'tests' dir)
    tests_dir = os.path.dirname(os.path.abspath(__file__))
    proj_dir = os.path.dirname(tests_dir)
    
    rtl_dir = os.path.join(proj_dir, "RTL")
    
    print(f"Project Dir: {proj_dir}")
    print(f"RTL Dir: {rtl_dir}")

    run(
        verilog_sources={
            "burst_master": {"files": [os.path.join(rtl_dir, "simple_fifo.v"), os.path.join(rtl_dir, "burst_master.v")], "toplevel": "burst_master"},
            "burst_master_2": {"files": [os.path.join(rtl_dir, "simple_fifo.v"), os.path.join(rtl_dir, "burst_master_2.v")], "toplevel": "burst_master_2"},
            "burst_master_3": {"files": [os.path.join(rtl_dir, "simple_fifo.v"), os.path.join(rtl_dir, "burst_master_3.v")], "toplevel": "burst_master_3"}
        },
        module="tb_burst_master",
        python_search=[
            tests_dir
        ],
        sim="iverilog",
        waves=True,
        force_compile=True
    )

if __name__ == "__main__":
    test_burst_master()
