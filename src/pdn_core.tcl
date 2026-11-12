# Preserve the TT power grid. Join it to the fixed core's edge terminals.
source [file join [file dirname [info script]] pdn_standard_grid.tcl]
set ::tt_core_feed_script [file join [file dirname [info script]] pdn_core_feeds.tcl]
rename pdngen tt_core_original_pdngen
proc pdngen {args} {
    uplevel 1 [list tt_core_original_pdngen {*}$args]
    source $::tt_core_feed_script
}
