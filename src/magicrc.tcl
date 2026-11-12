# LibreLane normally sources this after the rcfile; load it here for PDK paths.
if {[info exists ::env(_TCL_ENV_IN)]} {source $::env(_TCL_ENV_IN)}
# Keep the complete PDK setup for all Magic steps.
source [file join $::env(PDK_ROOT) $::env(PDK) libs.tech magic "$::env(PDK).magicrc"]

# Extraction only: inline small geometry cells (principally ICC2 via cells).
# Inline the macro routing hierarchy too: otherwise tied output ports cross
# hierarchy boundaries and ext2spice drops aliases despite "short resistor".
# Standard-cell and SRAM device geometry remains fully extracted and compared.
# This changes the extraction hierarchy, never the submitted GDS geometry.
if {[info exists ::env(_MAGIC_SCRIPT)] &&
    [file tail $::env(_MAGIC_SCRIPT)] eq "extract_spice.tcl"} {
    gds ordering on
    gds flatten 10
    gds flatglob acc_hard_macro
}

if {[info exists ::env(_MAGIC_SCRIPT)] &&
    [file tail $::env(_MAGIC_SCRIPT)] eq "extract_spice.tcl"} {
    set ::tt_lvs_scripts [file normalize [file join [file dirname [info script]] .. scripts]]
    exec python3 [file join $::tt_lvs_scripts check_lvs_inputs.py]
    # Canonicalize only explicit ideal-zero aliases after extraction. Keep the
    # raw result and the independent transformation audit in the run directory.
    proc tt_canonicalize_lvs_output {command code result operation} {
        if {$code != 0} {return}
        set args [lrange $command 1 end]
        set oi [lsearch -exact $args -o]
        if {$oi >= 0} {
            set output [lindex $args [expr {$oi + 1}]]
            if {![file exists $output]} {error "Missing extracted SPICE: $output"}
            file copy -force $output "$output.raw"
            exec python3 [file join $::tt_lvs_scripts normalize_lvs_aliases.py] $output "$output.canonical"
            file rename -force "$output.canonical" $output
        }
    }
    trace add execution ext2spice leave tt_canonicalize_lvs_output
}
