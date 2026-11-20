# Current top-level protocol: UART input + board-preloaded PSRAM program/weights.
COCOTB_RESULTS_FILE ?= $(CURDIR)/results.xml
ifeq ($(GATES),yes)
include Makefile.gates
else
include Makefile.stream
endif
