# Extend TT's vertical met4 power stripes across the placement halo to the
# OpenRAM macro's outer met3 power rings. Never route across the array interior.
set block [ord::get_db_block]
set tech [ord::get_db_tech]
set inst [$block findInst sram]
if {$inst == "NULL"} {error "Expected SRAM-only instance sram"}
set bbox [$inst getBBox]
set mx1 [$bbox xMin]
set my1 [$bbox yMin]
set mx2 [$bbox xMax]
set my2 [$bbox yMax]
set m4 [$tech findLayer met4]
# Reuse a legal generated met3/met4 via that fits the 1.6um stripe and ring.
set via "NULL"
foreach candidate [$block getVias] {
    set layers {}
    set fits 1
    foreach box [$candidate getBoxes] {
        set layer [$box getTechLayer]
        if {[$layer getRoutingLevel] > 0} {
            lappend layers [$layer getName]
            if {[$box getDX] > 1600 || [$box getDY] > 1740} {set fits 0}
        }
    }
    if {$fits && [lsort -unique $layers] == {met3 met4}} {set via $candidate; break}
}
if {$via == "NULL"} {error "No legal met3/met4 via fits the SRAM straps"}
foreach {netname pinname} {VPWR vccd1 VGND vssd1} {
    set net [$block findNet $netname]
    set rings {}
    set iterm [$inst findITerm $pinname]
    foreach mpin [[$iterm getMTerm] getMPins] {
        foreach box [$mpin getGeometry] {
            if {[[$box getTechLayer] getName] == "met3" && [$box getDX] > 500000} {
                lappend rings [expr {$my1+([$box yMin]+[$box yMax])/2}]
            }
        }
    }
    set rings [lsort -integer $rings]
    if {[llength $rings] != 2} {error "Expected two horizontal $pinname rings"}
    set endpoints {}
    foreach sw [$net getSWires] {
        foreach box [$sw getWires] {
            if {![$box isVia] && [[$box getTechLayer] getName] == "met4" &&
                [$box xMin] > $mx1+10000 && [$box xMax] < $mx2-10000 &&
                ([$box yMax] < $my1 || [$box yMin] > $my2)} {
                lappend endpoints [list [$box xMin] [$box yMin] [$box xMax] [$box yMax]]
            }
        }
    }
    if {[llength $endpoints] == 0} {error "No $netname stripes adjacent to SRAM"}
    set sw [odb::dbSWire_create $net ROUTED]
    foreach rect $endpoints {
        lassign $rect x1 y1 x2 y2
        set cx [expr {($x1+$x2)/2}]
        if {$y2 < $my1} {
            set cy [lindex $rings 0]
            set ny1 $y1
            set ny2 [expr {$cy+165}]
        } else {
            set cy [lindex $rings 1]
            set ny1 [expr {$cy-165}]
            set ny2 $y2
        }
        odb::dbSBox_create $sw $m4 $x1 $ny1 $x2 $ny2 STRIPE
        odb::dbSBox_create $sw $via $cx $cy STRIPE
    }
}
