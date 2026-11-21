set_app_var sh_continue_on_error false
set ::tt_batch_mode 1
set root $::env(ACC_ROOT)
set run $::env(ACC_FIT_RUN)
if {[catch {
open_lib $run/acc_hard_macro.ndm
open_block acc_hard_macro/final_clean
foreach {net pins} {VPWR {itf/diode3799/VPB} VGND {itf/diode3799/VNB}} {
 set p [get_pins -physical_context $pins]
 if {[sizeof_collection $p] != 1} {error "Missing body pin $pins"}
 connect_pg_net -net $net $p
}
source $root/pnr/core/setup.tcl
source $root/pnr/core/antenna.tcl
save_block -as acc_hard_macro/final_clean
save_lib
source $root/pnr/core/export_final.tcl
set f [open $run/export_path.txt w];puts $f $tt_export_dir;close $f
} message]} {puts stderr $message;puts stderr $::errorInfo;exit 1}
exit 0
