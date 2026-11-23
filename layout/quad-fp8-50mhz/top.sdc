# TT SKY130 b22cd30, GDS run 43060864621; ns/pF.
# OUTPUT_CAP_LOAD=33.442 fF -> 0.033442 pF (write_sdc rounds to 0.0334).
# 50 MHz target. Historical 20 ns IO budgets still require board-specific review.
# Pre-CTS ideal clock; after CTS: set_propagated_clock [get_clocks clk].
create_clock -name clk -period 20.0 [get_ports clk]
set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition 0.15 [get_clocks clk]
set data_inputs [get_ports {uart_rx_i qspi_dq_i* rst_n}]
set_input_delay 20.0 -clock [get_clocks clk] $data_inputs
set_output_delay 20.0 -clock [get_clocks clk] [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise 0.0 -input_transition_fall 0.0 [all_inputs]
set_load -pin_load 0.033442 [all_outputs]
set_max_fanout 10 [current_design]
set_max_transition 0.75 [current_design]
set_max_capacitance 0.2 [current_design]
set_timing_derate -early 0.95
set_timing_derate -late 1.05
# No reset/SPI false paths, matching TT generic verification.
