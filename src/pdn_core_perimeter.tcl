# Join the upper/lower wrapper rails outside the hardened core. The core's
# edge-only LEF power ports must not be treated as an implicit through-wire.
# Keep the TT M4 stripe positions and the core GDS unchanged.
set block [ord::get_db_block]
set tech [ord::get_db_tech]
set units [$block getDbUnitsPerMicron]
set m3 [$tech findLayer met3]
set die [$block getDieArea]
if {abs(double([$die xMax])/$units-1378.16)>0.001 ||
    abs(double([$die yMax])/$units-225.76)>0.001} {
    error "Unexpected die size: fixed TT perimeter PG contract invalid"
}

# Supply rails in the reserved bottom corridor. VPWR is 0.40 um below
# the former row-edge rail: its upper edge 5.28 leaves 0.38 um to core M1.
# Keep the outer VGND rail at the original y=2.72.
foreach {netname y} {VPWR 5.04 VGND 2.72} {
    set sw [odb::dbSWire_create [$block findNet $netname] ROUTED]
    odb::dbSBox_create $sw [$tech findLayer met1] \
        [expr {round(2.76*$units)}] [expr {round(($y-0.24)*$units)}] \
        [expr {round(1375.40*$units)}] [expr {round(($y+0.24)*$units)}] STRIPE
}

# Two 0.6 um M3 wires in the right-hand corridor, outside core xMax=1372.64.
# VPWR ends at x=1373.30: this leaves 0.33 um to the existing right
# VGND M1-M4 stack M3 landing pad (starts at x=1373.63).
foreach {netname x} {VPWR 1373.00 VGND 1374.45} {
    set net [$block findNet $netname]
    set sw [odb::dbSWire_create $net ROUTED]
    odb::dbSBox_create $sw $m3 \
        [expr {round(($x-0.3)*$units)}] [expr {round(2.48*$units)}] \
        [expr {round(($x+0.3)*$units)}] [expr {round(223.28*$units)}] STRIPE

    # Materialize the existing left M4 supply terminal as routed metal so
    # pdngen can build a real M1-M4 via stack at its same-net rail crossing.
    # This duplicates its existing pin rectangle; it does not relocate the pin.
    set terminal_count 0
    foreach bt [$net getBTerms] {
        foreach bp [$bt getBPins] {
            foreach box [$bp getBoxes] {
                if {[$box xMax] < round(5.52*$units)} {
                    if {[[$box getTechLayer] getName] ne "met4"} {
                        error "Unexpected left supply terminal layer"
                    }
                    odb::dbSBox_create $sw [$box getTechLayer] \
                        [$box xMin] [$box yMin] [$box xMax] [$box yMax] STRIPE
                    incr terminal_count
                }
            }
        }
    }
    if {$terminal_count == 0} {
        # Reserving the bottom row may remove pdngen's left VPWR stub.
        # Restore the same terminal rectangle explicitly, not a new location.
        if {$netname eq "VPWR"} {set ys {2.48 11.12}} else {set ys {214.64 223.28}}
        set bt [$block findBTerm $netname]
        if {$bt == "NULL"} {error "Missing supply port $netname"}
        set bp [odb::dbBPin_create $bt]
        $bp setPlacementStatus FIRM
        set box [list [expr {round(3.74*$units)}] [expr {round([lindex $ys 0]*$units)}] [expr {round(4.54*$units)}] [expr {round([lindex $ys 1]*$units)}]]
        odb::dbBox_create $bp [$tech findLayer met4] {*}$box
        odb::dbSBox_create $sw [$tech findLayer met4] {*}$box STRIPE
        incr terminal_count
    }
    if {$terminal_count != 1} {error "Expected one left M4 terminal for $netname, got $terminal_count"}
}
