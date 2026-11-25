TOPLEVEL_LANG = verilog
TOPLEVEL = tb_quad_wrapper
COCOTB_TEST_MODULES = test_quad_wrapper
ROOT := $(abspath $(CURDIR)/..)
BUILD ?= /tmp/acc-serial
SIM_BUILD = $(BUILD)/sim
COCOTB_RESULTS_FILE ?= $(CURDIR)/results.xml
export GATES
ifeq ($(GATES),yes)
SIM ?= icarus
COMPILE_ARGS += -DCOCOTB_SIM -DGL_TEST -DUSE_POWER_PINS -DFUNCTIONAL -DSIM -DUNIT_DELAY=\#1
VERILOG_SOURCES = $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
VERILOG_SOURCES += $(ROOT)/macro/acc_hard_macro/acc_hard_macro.v
VERILOG_SOURCES += $(CURDIR)/gate_level_netlist.v
else
SIM ?= verilator
VERILOG_SOURCES = $(addprefix $(ROOT)/,$(shell cat $(ROOT)/src/sources.f))
VERILOG_SOURCES += $(ROOT)/src/wrapper/project.v
COMPILE_ARGS += -DCOCOTB_SIM -Wno-fatal --timing --timescale-override 1ns/1ps
endif
VERILOG_SOURCES += $(ROOT)/memory/openram/generated/tt_sram_1rw_64x64_sky130/tt_sram_1rw_64x64_sky130.v
VERILOG_SOURCES += $(CURDIR)/rtl/tb/tb_quad_wrapper.sv $(CURDIR)/rtl/models/qspi_psram_model.sv
include $(shell cocotb-config --makefiles)/Makefile.sim
