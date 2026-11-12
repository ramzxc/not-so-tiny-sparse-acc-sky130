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

# Two 0.6 um M3 wires in the right-hand corridor, outside core xMax=1372.64.
# Their 0.5 um mutual spacing also leaves room for the generated via enclosures.
foreach {netname x} {VPWR 1373.35 VGND 1374.45} {
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
    if {$terminal_count != 1} {error "Expected one left M4 terminal for $netname, got $terminal_count"}
}
