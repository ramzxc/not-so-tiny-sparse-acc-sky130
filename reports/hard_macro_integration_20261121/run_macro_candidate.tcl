# Isolated batch run requested for the rebuilt RTL; no published macro replacement.
set batch_script_dir [file dirname [file normalize [info script]]]
set ::tt_batch_mode 1
set_app_var sh_continue_on_error false
proc batch_checkpoint {name} {
    global PNR_OUT TOP
    save_block -as ${TOP}/$name
    save_lib
    file mkdir $PNR_OUT/reports
    redirect -file $PNR_OUT/reports/${name}_qor.rpt {report_qor}
    redirect -file $PNR_OUT/reports/${name}_utilization.rpt {report_utilization}
    write_def $PNR_OUT/${name}.def
    redirect -file $PNR_OUT/reports/${name}_timing.rpt {report_timing -max_paths 10}
    puts "TT_PNR_STAGE $name"
}
proc batch_run {} {
    global batch_script_dir ROOT PNR_OUT
    source $batch_script_dir/import.tcl
    # Import creates globals used by existing manual scripts.
}
# Source at global scope so existing setup/export scripts see the same variables.
if {[catch {
    source $batch_script_dir/import.tcl
    set_host_options -max_cores 8
    source $ROOT/pnr/core/init.tcl
    source $ROOT/pnr/core/apply_pg.tcl
    batch_checkpoint floorplan
    source $ROOT/pnr/core/insert_taps.tcl
    batch_checkpoint taps
    place_opt
    source $ROOT/pnr/core/fix_post_clock_pg.tcl
    batch_checkpoint placed
    source $ROOT/pnr/core/prepare_cts.tcl
    clock_opt
    source $ROOT/pnr/core/fix_post_clock_pg.tcl
    batch_checkpoint clocked
    source $ROOT/pnr/core/antenna.tcl
    route_auto
    batch_checkpoint routed
    route_opt
    source $ROOT/pnr/core/fix_post_clock_pg.tcl
    batch_checkpoint optimized
    source $ROOT/pnr/core/insert_fillers.tcl
    batch_checkpoint filled
    redirect -file $PNR_OUT/reports/final_routes.rpt {check_routes}
    redirect -file $PNR_OUT/reports/final_legality.rpt {check_legality -verbose}
    redirect -file $PNR_OUT/reports/final_utilization.rpt {report_utilization}
    write_def $PNR_OUT/area_fit.def
    write_verilog $PNR_OUT/area_fit.v
    write_sdc -output $PNR_OUT/area_fit.sdc
    batch_checkpoint final
    puts "TT_PNR_COMPLETE $PNR_OUT"
} message]} {
    puts stderr "TT_PNR_FAILED: $message"
    puts stderr $::errorInfo
    catch {save_block -as ${TOP}/failed}
    catch {save_lib}
    exit 1
}
exit 0
