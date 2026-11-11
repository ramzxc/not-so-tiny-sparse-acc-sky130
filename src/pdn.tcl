# Preserve TT's standard grid and all downstream connectivity/DRC checks.
source [file join [file dirname [info script]] pdn_standard_grid.tcl]
# PDN_CFG is evaluated before pdngen; extend the generated edge stripes before
# LibreLane writes its database and runs check_power_grid.
set ::tt_sram_connection_script [file join [file dirname [info script]] pdn_sram_connections.tcl]
rename pdngen tt_sram_standard_pdngen
proc pdngen {args} {
    uplevel 1 [list tt_sram_standard_pdngen {*}$args]
    source $::tt_sram_connection_script
}
