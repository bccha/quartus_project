# Cocotb Test Makefile

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES += $(PWD)/../../RTL/my_slave.v
VERILOG_SOURCES += $(PWD)/../../ip/dpram.v

# 만약 ip/dpram.v 가 Altera 라이브러리를 필요로 한다면 추가적인 파일이 필요할 수 있습니다.
# iverilog 사용시 필요한 Altera stub 파일 예시:
# VERILOG_SOURCES += /path/to/altera_mf.v

TOPLEVEL = my_custom_slave
MODULE = tb_my_slave

include $(shell cocotb-config --makefiles)/Makefile.sim
