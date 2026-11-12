# The bottom wrapper row abuts the core at y=5.44. Its upper M1 cell pins
# and followpin rail would extend to y=5.68, too close to real core M1 at
# y=5.66. Reserve this wrapper row before placement/filler insertion.
# The core and its internal rows/cells are not modified.
set block [ord::get_db_block]
set units [$block getDbUnitsPerMicron]
set removed_rows 0
set ::tt_reserved_rows {}
foreach row [$block getRows] {
    set box [$row getBBox]
    if {[$box yMin] == round(2.72*$units) && [$box yMax] == round(5.44*$units)} {
        lappend ::tt_reserved_rows [list [$row getName] [$row getSite] {*}[$row getOrigin] [$row getOrient] [$row getDirection] [$row getSiteCount] [$row getSpacing]]
        # Hard blockage excludes cells/filler, while the restored row keeps
        # OpenROAD's placement canvas large enough for the fixed core.
        odb::dbBlockage_create $block [$box xMin] [$box yMin] [$box xMax] [$box yMax]
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
puts "Reserved bottom wrapper row: temporarily withheld $removed_rows rows from PDN; removed $removed_cells tap/endcap instances"

proc tt_restore_reserved_rows {} {
    set block [ord::get_db_block]
    foreach row $::tt_reserved_rows {odb::dbRow_create $block {*}$row}
    set ::tt_reserved_rows {}
}
