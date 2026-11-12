# The bottom wrapper row abuts the core at y=5.44. Its upper M1 cell pins
# and followpin rail would extend to y=5.68, too close to real core M1 at
# y=5.66. Reserve this wrapper row before placement/filler insertion.
# The core and its internal rows/cells are not modified.
set block [ord::get_db_block]
set units [$block getDbUnitsPerMicron]
set removed_rows 0
foreach row [$block getRows] {
    set box [$row getBBox]
    if {[$box yMin] == round(2.72*$units) && [$box yMax] == round(5.44*$units)} {
        odb::dbRow_destroy $row
        incr removed_rows
    }
}
set removed_cells 0
foreach inst [$block getInsts] {
    set name [$inst getName]
    if {![string match TAP_TAPCELL_* $name] && ![string match PHY_EDGE_* $name]} {continue}
    set box [$inst getBBox]
    if {[$box yMin] >= round(2.72*$units) && [$box yMax] <= round(5.44*$units)} {
        odb::dbInst_destroy $inst
        incr removed_cells
    }
}
puts "Reserved bottom wrapper row: removed $removed_rows rows and $removed_cells tap/endcap instances"
