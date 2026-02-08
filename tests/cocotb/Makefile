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
# Note: Using immediate assignment if possible or ensuring clean build
ifeq ($(TOPLEVEL),my_custom_slave)
    VERILOG_SOURCES = $(PWD)/../../RTL/my_slave.v \
                      $(PWD)/../../ip/dpram.v \
                      $(PWD)/sim_models/altsyncram.v
else ifeq ($(TOPLEVEL),stream_processor)
    VERILOG_SOURCES = $(PWD)/../../RTL/stream_processor.v
endif

# Common Altera models (if needed)
# VERILOG_SOURCES += $(PWD)/sim_models/altsyncram.v

.PHONY: all_tests pytest_clean
all_tests:
	make clean MODULE=tb_my_slave TOPLEVEL=my_custom_slave
	make clean MODULE=tb_stream_processor_avs TOPLEVEL=stream_processor

pytest_clean:
	rm -rf sim_build
	rm -f *_results.xml results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
