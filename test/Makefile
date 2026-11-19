# Current top-level protocol: UART input + board-preloaded PSRAM program/weights.
ifeq ($(GATES),yes)
$(error Historical gate-level netlists are not valid for the PSRAM stream build)
endif
COCOTB_RESULTS_FILE ?= $(CURDIR)/results.xml
include Makefile.stream
