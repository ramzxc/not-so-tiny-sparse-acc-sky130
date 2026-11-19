# Read-only timing diagnostic on a previously synthesized DDC; no compile.
source [file join [file dirname [info script]] ../syn/script/setup.tcl]
read_ddc $::env(ACC_STAGE_DDC)
current_design acc_hard_macro
link
redirect -file $REPORTS/register_timing.rpt {
    report_timing -from [all_registers -clock_pins] -to [all_registers -data_pins] -max_paths 5
}
exit
