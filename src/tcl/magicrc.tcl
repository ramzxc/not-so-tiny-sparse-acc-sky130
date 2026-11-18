# Full PDK setup; prepare SRAM device models using the active extraction deck.
if {[info exists ::env(_TCL_ENV_IN)]} {source $::env(_TCL_ENV_IN)}
source [file join $::env(PDK_ROOT) $::env(PDK) libs.tech magic "$::env(PDK).magicrc"]
if {[info exists ::env(_MAGIC_SCRIPT)] && [file tail $::env(_MAGIC_SCRIPT)] eq "extract_spice.tcl"} {
    exec python3 [file normalize [file join [file dirname [info script]] ../../scripts/prepare_sram_lvs.py]]
}
