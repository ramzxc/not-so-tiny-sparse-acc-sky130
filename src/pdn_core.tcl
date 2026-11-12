# Preserve the TT grid; connect the fixed core and wrapper with real metal/vias.
source [file join [file dirname [info script]] pdn_core_rows.tcl]
source [file join [file dirname [info script]] pdn_standard_grid.tcl]
set ::tt_core_feed_script [file join [file dirname [info script]] pdn_core_feeds.tcl]
set ::tt_core_perimeter_script [file join [file dirname [info script]] pdn_core_perimeter.tcl]
rename pdngen tt_core_original_pdngen
proc pdngen {args} {
    # Control/report calls must not create additional geometry.
    foreach flag {-reset -ripup -report_only -check_only} {
        if {$flag in $args} {return [uplevel 1 [list tt_core_original_pdngen {*}$args]]}
    }
    uplevel 1 [list tt_core_original_pdngen {*}$args]
    source $::tt_core_feed_script
    source $::tt_core_perimeter_script

    # The manual feed rectangles are inserted after the standard grid. Run a
    # via-generation pass over existing shapes so those wires are connected,
    # including M1 rails, M3 perimeter wires and the left M4 supply terminals.
    # -reset clears grid specifications, not the already generated geometry.
    tt_core_original_pdngen -reset
    define_pdn_grid -name wrapper_existing -existing
    add_pdn_connect -grid wrapper_existing -layers {met1 met3}
    add_pdn_connect -grid wrapper_existing -layers {met1 met4}
    set via_args [list -dont_add_pins]
    set idx [lsearch -exact $args -failed_via_report]
    if {$idx >= 0} {lappend via_args -failed_via_report [lindex $args [expr {$idx+1}]]}
    tt_core_original_pdngen {*}$via_args
    foreach net {VPWR VGND} {check_power_grid -net $net}
}
