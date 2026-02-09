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
    (
        "burst_master", 
        "tb_burst_master", 
        [
            os.path.join(PROJ_PATH, "RTL", "burst_master.v"),
            os.path.join(PROJ_PATH, "RTL", "simple_fifo.v")
        ]
    ),
    (
        "burst_master_2", 
        "tb_burst_master", 
        [
            os.path.join(PROJ_PATH, "RTL", "burst_master_2.v"),
            os.path.join(PROJ_PATH, "RTL", "simple_fifo.v")
        ]
    ),
])
def test_cocotb_modules(toplevel, module, sources):
    """Pytest runner for Cocotb tests"""
    sim_build = os.path.join("sim_build", toplevel)
    run(
        verilog_sources=sources,
        toplevel=toplevel,
        module=module,
        simulator="icarus",
        waves=True, # cocotb-test의 표준 파형 덤프 활성화
        sim_build=sim_build, # 각 모듈별로 독립된 빌드 디렉토리 사용 (충돌 방지)
        results_xml=os.path.join(sim_build, "results.xml") # XML 결과 파일을 빌드 폴더 내로 집중
    )
