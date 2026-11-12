################################################################################
#
# Design name:  acc_hard_macro
#
# Created by icc2 write_sdc on Thu Nov 12 21:16:12 2026
#
################################################################################

set sdc_version 2.2
set_units -time ns -resistance kOhm -capacitance pF -voltage V -current mA

################################################################################
#
# Units
# time_unit               : 1e-09
# resistance_unit         : 1000
# capacitive_load_unit    : 1e-12
# voltage_unit            : 1
# current_unit            : 0.001
# power_unit              : 1e-09
################################################################################


# Mode: functional
# Corner: tt
# Scenario: functional_tt

# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   4; /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/pnr/core/prepare_cts.tcl, \
#   line 50
create_clock -name clk -period 100 -waveform {0 50} [get_ports {clk}]
set_propagated_clock [get_clocks {clk}]
set_load -pin_load 0.033442 [get_ports {uo_out[7]}]
set_load -pin_load 0.033442 [get_ports {uo_out[6]}]
set_load -pin_load 0.033442 [get_ports {uo_out[5]}]
set_load -pin_load 0.033442 [get_ports {uo_out[4]}]
set_load -pin_load 0.033442 [get_ports {uo_out[3]}]
set_load -pin_load 0.033442 [get_ports {uo_out[2]}]
set_load -pin_load 0.033442 [get_ports {uo_out[1]}]
set_load -pin_load 0.033442 [get_ports {uo_out[0]}]
set_load -pin_load 0.033442 [get_ports {uio_out[7]}]
set_load -pin_load 0.033442 [get_ports {uio_out[6]}]
set_load -pin_load 0.033442 [get_ports {uio_out[5]}]
set_load -pin_load 0.033442 [get_ports {uio_out[4]}]
set_load -pin_load 0.033442 [get_ports {uio_out[3]}]
set_load -pin_load 0.033442 [get_ports {uio_out[2]}]
set_load -pin_load 0.033442 [get_ports {uio_out[1]}]
set_load -pin_load 0.033442 [get_ports {uio_out[0]}]
set_load -pin_load 0.033442 [get_ports {uio_oe[7]}]
set_load -pin_load 0.033442 [get_ports {uio_oe[6]}]
set_load -pin_load 0.033442 [get_ports {uio_oe[5]}]
set_load -pin_load 0.033442 [get_ports {uio_oe[4]}]
set_load -pin_load 0.033442 [get_ports {uio_oe[3]}]
set_load -pin_load 0.033442 [get_ports {uio_oe[2]}]
set_load -pin_load 0.033442 [get_ports {uio_oe[1]}]
set_load -pin_load 0.033442 [get_ports {uio_oe[0]}]
# Warning: Libcell power domain derates are skipped!

# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   15
set_timing_derate -early 0.95 -cell_delay -clock [current_design]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   16
set_timing_derate -late 1.05 -cell_delay -clock [current_design]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   15
set_timing_derate -early 0.95 -cell_delay -data [current_design]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   16
set_timing_derate -late 1.05 -cell_delay -data [current_design]
set_timing_derate -early 0.95 -net_delay -clock 
set_timing_derate -late 1.05 -net_delay -clock 
set_timing_derate -early 0.95 -net_delay -data 
set_timing_derate -late 1.05 -net_delay -data 
# Set latency for io paths.
# -origin useful_skew
set_clock_latency -min 1.0852 [get_clocks {clk}]
# -origin useful_skew
set_clock_latency -max 1.19946 [get_clocks {clk}]
# Set propagated on clock sources to avoid removing latency for IO paths.
set_propagated_clock  [get_ports {clk}]
set_clock_uncertainty 0.25 [get_clocks {clk}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {ui_in[7]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {ui_in[6]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {ui_in[5]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {ui_in[4]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {ui_in[3]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {ui_in[2]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {ui_in[1]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {ui_in[0]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {uio_in[7]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {uio_in[6]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {uio_in[5]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {uio_in[4]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {uio_in[3]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {uio_in[2]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {uio_in[1]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {uio_in[0]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {ena}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {clk}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   10
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y -input_transition_rise \
    0 -input_transition_fall 0 [get_ports {rst_n}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {ui_in[7]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {ui_in[6]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {ui_in[5]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {ui_in[4]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {ui_in[3]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {ui_in[2]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {ui_in[1]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {ui_in[0]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uo_out[7]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uo_out[6]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uo_out[5]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uo_out[4]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uo_out[3]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uo_out[2]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uo_out[1]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uo_out[0]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {uio_in[7]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {uio_in[6]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {uio_in[5]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {uio_in[4]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {uio_in[3]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {uio_in[2]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {uio_in[1]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {uio_in[0]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_out[7]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_out[6]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_out[5]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_out[4]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_out[3]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_out[2]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_out[1]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_out[0]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_oe[7]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_oe[6]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_oe[5]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_oe[4]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_oe[3]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_oe[2]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_oe[1]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   9
set_output_delay -clock [get_clocks {clk}] 20 [get_ports {uio_oe[0]}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {ena}]
# /docker/projects/tapeout/not-so-tiny-sparse-acc-sky130/syn/cons/top.sdc, line \
#   8
set_input_delay -clock [get_clocks {clk}] 20 [get_ports {rst_n}]
set_max_transition 0.75 [current_design]
set_max_capacitance 0.2 [current_design]
