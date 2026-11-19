# Local comparison only; no submission files or syn/LATEST are updated.
# ACC_MANUAL_OUT=<new path> [STREAM_BASELINE_RTL=<saved rtl dir>] dc_shell -f ...
source [file join [file dirname [info script]] ../syn/script/setup.tcl]
if {[info exists ::env(STREAM_BASELINE_RTL)]} {
    set base $::env(STREAM_BASELINE_RTL)
    set RTL {}
    foreach f {shared_sram.sv project.v uart/uart_rx.v uart/uart_tx.v core/inst_fifo.v core/micro_ctrl.v core/dma_ctrl.v core/inst_decoder.v core/data_ctrl.v core/exec_unit.sv mem_itf.sv qspi_ctrl.v} {
        lappend RTL [file join $base $f]
    }
    set_app_var search_path [concat [list $base [file join $base core]] $search_path]
}
# Optional immutable source snapshot for staged comparisons.
if {[info exists ::env(ACC_RTL_SNAPSHOT)]} {
    set snapshot [file normalize $::env(ACC_RTL_SNAPSHOT)]
    set saved_rtl {}
    foreach f $RTL {lappend saved_rtl [string map [list $ROOT/src $snapshot/src] $f]}
    set RTL $saved_rtl
    set_app_var search_path [concat [list $snapshot/src/rtl $snapshot/src/rtl/core] $search_path]
}
set_host_options -max_cores 2
acc_read_rtl
create_clock -name clk -period 20 [get_ports clk]
set hierarchy [get_cells -hierarchical -filter {is_hierarchical == true}]
set_ungroup $hierarchy false
set_boundary_optimization $hierarchy false
if {![compile_ultra -no_autoungroup]} {error "Compile failed"}
redirect -file $REPORTS/area.rpt {report_area -hierarchy}
redirect -file $REPORTS/qor.rpt {report_qor}
redirect -file $REPORTS/check_design.rpt {check_design}
redirect -file $REPORTS/timing.rpt {report_timing -max_paths 5}
write -format ddc -hierarchy -output $OUT/core.ddc
puts "STREAM_AREA_COMPLETE"
exit
