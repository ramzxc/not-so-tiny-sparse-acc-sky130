set_app_var sh_continue_on_error false
set run $::env(ACC_FIT_RUN)
if {[catch {
open_lib $run/acc_hard_macro.ndm
open_block acc_hard_macro/final
set spare [get_shapes -quiet __empty__]
foreach name {VPWR VGND} {
 foreach_in_collection shape [get_shapes -of_objects [get_nets $name]] {
  lassign [get_attribute $shape bbox] ll ur
  if {[get_attribute $shape layer_name] eq "met1" && [lindex $ll 0]>=1357.119 && [lindex $ur 0]<=1364.321} {
   set spare [add_to_collection $spare $shape]
  }
 }
}
if {[sizeof_collection $spare]!=77} {error "Unexpected count of isolated right keepout rail fragments"}
remove_shapes -force $spare
redirect -file $run/reports/clean_pg.rpt {check_pg_connectivity -nets {VPWR VGND}}
redirect -file $run/reports/clean_pg_drc.rpt {check_pg_drc -nets {VPWR VGND}}
set db [open_drc_error_data DRC_report_by_check_pg_drc]
if {[sizeof_collection [get_drc_errors -quiet -error_data $db]]} {error "PG DRC after cleanup"}
redirect -file $run/reports/clean_routes.rpt {check_routes -antenna true}
save_block -as acc_hard_macro/final_clean
save_lib
puts "FIT_CLEAN_COMPLETE removed 77 unused right keepout rail fragments"
} message]} {puts stderr $message;puts stderr $::errorInfo;exit 1}

set_app_var sh_continue_on_error false
set ::tt_batch_mode 1
if {[catch {
set run $::env(ACC_FIT_RUN)

open_block acc_hard_macro/$::env(ACC_AUDIT_STAGE)
set_host_options -max_cores 4
set root $::env(ACC_ROOT)
source $root/pnr/core/setup.tcl
source $root/pnr/core/antenna.tcl
file mkdir $run/audit
set out [open $run/audit/cells.tsv w]
puts $out "name\tref\tbbox\tstatus"
foreach_in_collection cell [get_cells -hierarchical -physical_context -filter {is_hierarchical == false}] {
    puts $out "[get_object_name $cell]\t[get_attribute $cell ref_name]\t[get_attribute $cell bbox]\t[get_attribute $cell physical_status]"
}
close $out
set out [open $run/audit/geometry.txt w]
puts $out "BLOCK [get_object_name [current_block]]"
puts $out "BOUNDARY [get_attribute [current_block] boundary]"
set macro [get_cells -hierarchical -filter {ref_name == tt_sram_1rw_64x128_buffered_sky130}]
puts $out "SRAM [get_attribute $macro bbox]"
puts $out "ORIGIN [get_attribute $macro origin]"
puts $out "ORIENTATION [get_attribute $macro orientation]"
close $out
redirect -file $run/audit/legality.rpt {check_legality -verbose}
redirect -file $run/audit/utilization.rpt {report_utilization}
redirect -file $run/audit/qor.rpt {report_qor}
redirect -file $run/audit/internal_setup.rpt {report_timing -from [all_registers -clock_pins] -to [all_registers -data_pins] -delay_type max -max_paths 10}
redirect -file $run/audit/internal_hold.rpt {report_timing -from [all_registers -clock_pins] -to [all_registers -data_pins] -delay_type min -max_paths 10}
redirect -file $run/audit/all_timing.rpt {report_timing -max_paths 10}
redirect -file $run/audit/routes.rpt {check_routes}
redirect -file $run/audit/pg.rpt {check_pg_connectivity -nets {VPWR VGND}}
redirect -file $run/audit/pg_drc.rpt {check_pg_drc -nets {VPWR VGND}}
set out [open $run/audit/pg_shapes.tsv w]
foreach name {VPWR VGND} {
 foreach_in_collection shape [get_shapes -of_objects [get_nets $name]] {
  puts $out "$name\t[get_object_name $shape]\t[get_attribute $shape layer_name]\t[get_attribute $shape bbox]"
 }
}
close $out
write_def $run/audit/layout.def
puts "FIT_AUDIT_COMPLETE"
} message]} {puts stderr $message;puts stderr $::errorInfo;exit 1}

if {[catch {
current_scenario functional_tt
redirect -file $run/audit/constraints.rpt {report_constraints -all_violators -verbose -significant_digits 6}
source $root/pnr/core/export_final.tcl
set f [open $run/export_path.txt w];puts $f $tt_export_dir;close $f
puts "FIT_GDS_EXPORT_COMPLETE"
} message]} {puts stderr $message;puts stderr $::errorInfo;exit 1}
exit 0
