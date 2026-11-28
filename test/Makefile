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
GATE_POWER_DEFINES ?= -DUSE_POWER_PINS
COMPILE_ARGS += -DCOCOTB_SIM -DGL_TEST $(GATE_POWER_DEFINES) -DFUNCTIONAL -DSIM -DUNIT_DELAY=\#1
ifeq ($(TILE_GATES),yes)
COMPILE_ARGS += -DACC_TILE_GATES
endif
VERILOG_SOURCES = $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
GATE_MACRO_SOURCES ?= $(ROOT)/macro/acc_hard_macro/acc_hard_macro.v \
	$(ROOT)/memory/openram/generated/tt_sram_1rw_64x64_sky130/tt_sram_1rw_64x64_sky130.v
GATE_NETLIST ?= $(CURDIR)/gate_level_netlist.v
VERILOG_SOURCES += $(GATE_NETLIST) $(GATE_MACRO_SOURCES)
else
SIM ?= verilator
VERILOG_SOURCES = $(addprefix $(ROOT)/,$(shell cat $(ROOT)/src/sources.f))
VERILOG_SOURCES += $(ROOT)/src/wrapper/project.v
COMPILE_ARGS += -DCOCOTB_SIM -Wno-fatal --timing --timescale-override 1ns/1ps
VERILOG_SOURCES += $(ROOT)/memory/openram/generated/tt_sram_1rw_64x64_sky130/tt_sram_1rw_64x64_sky130.v
endif
VERILOG_SOURCES += $(CURDIR)/rtl/tb/tb_quad_wrapper.sv $(CURDIR)/rtl/models/qspi_psram_model.sv
include $(shell cocotb-config --makefiles)/Makefile.sim
