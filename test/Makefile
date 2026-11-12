# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
ifeq ($(GATES),yes)
SIM ?= icarus
else
SIM ?= verilator
endif
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(CURDIR)/../src
PROJECT_SOURCES = project.v acc_hard_macro_rtl.v tpu_pkg.sv acc_host.sv mem_ctrl.sv shared_sram.sv acc_spi.sv activation.sv activation_ctrl.sv axi_master_adapter.sv dma.sv inst_decoder.sv inst_fifo.sv mac_unit.sv sparsity_ctrl.sv tpu.sv tpu_core.sv vpu.sv vpu_ctrl.sv weight_load_ctrl.sv

SRAM_BYTES ?= 512
export SRAM_BYTES
COMPILE_ARGS += -DACC_SRAM_BYTES=$(SRAM_BYTES)
VERILOG_SOURCES += $(SRC_DIR)/../memory/openram/generated/tt_sram_1rw_64x128_sky130/tt_sram_1rw_64x128_sky130.v
VERILOG_SOURCES += $(SRC_DIR)/../memory/openram/generated/tt_sram_1rw_64x64_sky130/tt_sram_1rw_64x64_sky130.v

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/shared_$(SRAM_BYTES)
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST -DTT_ICC2_HARDMACRO
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

VERILOG_SOURCES += $(SRC_DIR)/../macro/acc_hard_macro/acc_hard_macro.pg.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(CURDIR)/gate_level_netlist.v

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR) -I$(CURDIR)

ifeq ($(SIM),verilator)
COMPILE_ARGS += -Wno-fatal --timing --timescale-override 1ns/1ps
endif

# Include the testbench sources:
VERILOG_SOURCES += $(CURDIR)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
COCOTB_RESULTS_FILE ?= $(CURDIR)/results.xml
include $(shell cocotb-config --makefiles)/Makefile.sim

# Never enable the narrow reset correction without proving the packaged netlist.
ifeq ($(GATES),yes)
.PHONY: check-icc2-reset
check-icc2-reset:
	python3 $(CURDIR)/check_icc2_reset.py
$(SIM_BUILD)/sim.vvp: check-icc2-reset $(CURDIR)/icc2_reset_x.vh
endif
