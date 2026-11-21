set_app_var sh_continue_on_error false
set ::tt_batch_mode 1
set root $::env(ACC_ROOT)
set run $::env(ACC_FIT_RUN)
if {[catch {
open_lib $run/acc_hard_macro.ndm
open_block acc_hard_macro/final_clean
current_scenario functional_tt
set_host_options -max_cores 8
source $root/pnr/core/setup.tcl
source $root/pnr/core/antenna.tcl
set fillers [get_cells -quiet -physical_context -filter {ref_name =~ sky130_fd_sc_hd__fill_*}]
remove_cells $fillers
set reset [get_pins reset_sync_reg_1_/Q]
if {[sizeof_collection $reset] != 1} {error "Reset ECO anchor changed"}
set reset_net [get_nets -of_objects $reset]
set changed $reset_net
foreach {target name} {command/sequencer/acc_addr_reg_7_ command/sequencer/TT_ACC_RESET dma/destination_reg_8_ dma/TT_DEST_RESET} {
 set d [get_pins $target/D]
 if {[sizeof_collection $d] != 1} {error "Reset ECO target changed"}
 set old [get_nets -of_objects $d]
 set gate [create_cell $name sky130_hd/sky130_fd_sc_hd__and2_1]
 create_net ${name}_D
 set new [get_nets ${name}_D]
 disconnect_net $old $d
 connect_net $old [get_pins $name/A]
 connect_net $reset_net [get_pins $name/B]
 connect_net $new [add_to_collection $d [get_pins $name/X]]
 set_attribute $gate origin [get_attribute [get_cells $target] origin]
 place_eco_cells -cells $gate -legalize_mode free_site_only
 set_dont_touch $gate true
 set changed [add_to_collection [add_to_collection $changed $old] $new]
}
set allcells [get_cells -hierarchical -physical_context -filter {is_hierarchical == false}]
foreach {net names} {VPWR {VPWR VPB vccd1} VGND {VGND VNB vssd1}} {
 foreach pin $names {connect_pg_net -net $net [get_pins -quiet -physical_context -of_objects $allcells -filter "name == $pin"]}
}
route_eco -nets $changed
route_detail -incremental true
source $root/pnr/core/insert_fillers.tcl
# Post-filler route repair can add antenna diodes and leave filler gaps.
create_stdcell_fillers -lib_cells $tt_fill_refs -prefix TT_REFILL
set allcells [get_cells -hierarchical -physical_context -filter {is_hierarchical == false}]
foreach {net names} {VPWR {VPWR VPB vccd1} VGND {VGND VNB vssd1}} {
 foreach pin $names {connect_pg_net -net $net [get_pins -quiet -physical_context -of_objects $allcells -filter "name == $pin"]}
}
source $root/pnr/core/fix_post_filler.tcl
save_block -as acc_hard_macro/final_clean
save_lib
source $root/pnr/core/export_final.tcl
set f [open $run/export_path.txt w];puts $f $tt_export_dir;close $f
} message]} {puts stderr $message;puts stderr $::errorInfo;catch {save_block -as acc_hard_macro/reset_repair_failed};catch {save_lib};exit 1}
exit 0
