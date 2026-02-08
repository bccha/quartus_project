import os
import pytest
from cocotb_test.simulator import run

# 프로젝트 루트 경로 설정 (RTL 및 IP 경로 확인용)
PROJ_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

@pytest.mark.parametrize("toplevel, module, sources", [
    (
        "my_custom_slave", 
        "tb_my_slave", 
        [
            os.path.join(PROJ_PATH, "RTL", "my_slave.v"),
            os.path.join(PROJ_PATH, "ip", "dpram.v"),
            os.path.join(os.path.dirname(__file__), "sim_models", "altsyncram.v")
        ]
    ),
    (
        "stream_processor", 
        "tb_stream_processor_avs", 
        [
            os.path.join(PROJ_PATH, "RTL", "stream_processor.v")
        ]
    ),
])
def test_cocotb_modules(toplevel, module, sources):
    """Pytest runner for Cocotb tests"""
    run(
        verilog_sources=sources,
        toplevel=toplevel,
        module=module,
        simulator="icarus",
        waves=True, # Waveform dumping 활성화
        # 필요시 별도의 시뮬레이션 인자 전달 가능
        # sim_args=["-W", "all"], 
    )
