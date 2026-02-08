# Cocotb Test Makefile
# Usage: 
#   make MODULE=tb_my_slave TOPLEVEL=my_custom_slave
#   make MODULE=tb_stream_processor_avs TOPLEVEL=stream_processor

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

# Default targets
TOPLEVEL ?= stream_processor
MODULE ?= tb_stream_processor_avs

# RTL Sources
ifeq ($(TOPLEVEL),my_custom_slave)
    VERILOG_SOURCES += $(PWD)/../../RTL/my_slave.v
    VERILOG_SOURCES += $(PWD)/../../ip/dpram.v
    VERILOG_SOURCES += $(PWD)/sim_models/altsyncram.v
else ifeq ($(TOPLEVEL),stream_processor)
    VERILOG_SOURCES += $(PWD)/../../RTL/stream_processor.v
endif

# Common Altera models (if needed)
# VERILOG_SOURCES += $(PWD)/sim_models/altsyncram.v

include $(shell cocotb-config --makefiles)/Makefile.sim
