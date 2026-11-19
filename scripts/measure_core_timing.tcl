# Local synthesis experiment, not signoff. Does not update syn/LATEST or submissions.
# ACC_MANUAL_OUT=/tmp/acc-sta50 dc_shell -f scripts/measure_core_timing.tcl
# Optional PERF_CLOCK_NS (default 20). Existing absolute IO delays are retained.
if {![info exists ::env(ACC_MANUAL_OUT)]} {error "Set ACC_MANUAL_OUT to a new experiment directory"}
set EXPERIMENT_ROOT [file normalize [file join [file dirname [info script]] ..]]
set PERIOD 20.0
if {[info exists ::env(PERF_CLOCK_NS)]} {set PERIOD $::env(PERF_CLOCK_NS)}
if {$PERIOD <= 0} {error "PERF_CLOCK_NS must be positive"}
if {[file exists [file join $::env(ACC_MANUAL_OUT) core.ddc]]} {error "Choose a new ACC_MANUAL_OUT"}
source [file join $EXPERIMENT_ROOT syn script setup.tcl]
set_host_options -max_cores 4
acc_read_rtl
create_clock -name clk -period $PERIOD [get_ports clk]
set hierarchy [get_cells -hierarchical -filter {is_hierarchical == true}]
set_ungroup $hierarchy false
set_boundary_optimization $hierarchy false
if {![compile_ultra -no_autoungroup]} {error "Compile failed"}
if {![compile_ultra -incremental -only_design_rule -no_autoungroup]} {error "Design-rule compile failed"}
redirect -file $REPORTS/area.rpt {report_area -hierarchy}
redirect -file $REPORTS/qor.rpt {report_qor}
redirect -file $REPORTS/timing_all.rpt {report_timing -delay_type max -max_paths 10}
redirect -file $REPORTS/timing_registers.rpt {
    report_timing -delay_type max -from [all_registers -output_pins] -to [all_registers -data_pins] -max_paths 10
}
redirect -file $REPORTS/timing_sram.rpt {
    report_timing -delay_type max -through [get_pins itf/memory/size_1k.macro/dout0*] -max_paths 2
}
redirect -file $REPORTS/check_timing.rpt {check_timing}
redirect -file $REPORTS/check_design.rpt {check_design}
write -format ddc -hierarchy -output $OUT/core.ddc
puts "PERF_SYNTH_COMPLETE"
exit
