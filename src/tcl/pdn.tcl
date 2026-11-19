# Fixed-core PDN integration. Grid parameters come from src/config.json.
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

# The wrapper uses the standard one-layer grid and followpin rails.
# Keep dimensions and enable flags in src/config.json / the PDK configuration.
# LibreLane 3.0.14's full default also creates an M4/M5 macro grid. Our core
# exposes M4-only power ports, so that grid is empty and fails PDN-0233.
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections
if {$::env(PDN_MULTILAYER) || $::env(PDN_CORE_RING)} {
    error "This fixed core requires the single-layer TT wrapper grid without a core ring"
}
if {$::env(VDD_NETS) ne $::env(VDD_NET) || $::env(GND_NETS) ne $::env(GND_NET)} {
    error "This fixed core supports one power/ground domain"
}
set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET)
set grid_args {}
if {$::env(PDN_ENABLE_PINS)} {lappend grid_args -pins $::env(PDN_VERTICAL_LAYER)}
define_pdn_grid -name stdcell_grid -starts_with POWER -voltage_domain CORE {*}$grid_args
set stripe_args {}
append_if_equals stripe_args PDN_EXTEND_TO core_ring -extend_to_core_ring
append_if_equals stripe_args PDN_EXTEND_TO boundary -extend_to_boundary
add_pdn_stripe -grid stdcell_grid -layer $::env(PDN_VERTICAL_LAYER) \
    -width $::env(PDN_VWIDTH) -pitch $::env(PDN_VPITCH) \
    -offset $::env(PDN_VOFFSET) -spacing $::env(PDN_VSPACING) \
    -starts_with POWER {*}$stripe_args
if {$::env(PDN_ENABLE_RAILS)} {
    add_pdn_stripe -grid stdcell_grid -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) -followpins
    add_pdn_connect -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
}

rename pdngen tt_core_original_pdngen
proc pdngen {args} {
    # Control/report calls must not create additional geometry.
    foreach flag {-reset -ripup -report_only -check_only} {
        if {$flag in $args} {return [uplevel 1 [list tt_core_original_pdngen {*}$args]]}
    }
    uplevel 1 [list tt_core_original_pdngen {*}$args]
    # Explicit same-net M4 feeds from the previously verified TT grid contract.
    set block [ord::get_db_block]
    set inst [$block findInst core]
    if {$inst == "NULL"} {error "Missing hardened core"}
    set units [$block getDbUnitsPerMicron]
    set bbox [$inst getBBox]
    foreach {actual expected} [list [$bbox xMin] 5.52 [$bbox yMin] 5.44 [$bbox xMax] 1372.64 [$bbox yMax] 220.32] {
        if {abs(double($actual)/$units-$expected)>0.001} {error "Unexpected core placement: PG contract invalid"}
    }
    set m4 [[ord::get_db_tech] findLayer met4]
    set feeds {
        {VPWR {18.280 2.480 19.880 6.440}}
        {VPWR {18.280 219.320 19.880 223.280}}
        {VPWR {57.150 2.480 58.750 6.440}}
        {VPWR {57.150 219.320 58.750 223.280}}
        {VPWR {96.020 2.480 97.620 6.440}}
        {VPWR {96.020 219.320 97.620 223.280}}
        {VPWR {134.890 2.480 136.490 6.440}}
        {VPWR {134.890 219.320 136.490 223.280}}
        {VPWR {173.760 2.480 175.360 6.440}}
        {VPWR {173.760 219.320 175.360 223.280}}
        {VPWR {212.630 2.480 214.230 6.440}}
        {VPWR {212.630 219.320 214.230 223.280}}
        {VPWR {251.500 2.480 253.100 6.440}}
        {VPWR {251.500 219.320 253.100 223.280}}
        {VPWR {290.370 2.480 291.970 6.440}}
        {VPWR {290.370 219.320 291.970 223.280}}
        {VPWR {329.240 2.480 330.840 6.440}}
        {VPWR {329.240 219.320 330.840 223.280}}
        {VPWR {368.110 2.480 369.710 6.440}}
        {VPWR {368.110 219.320 369.710 223.280}}
        {VPWR {406.980 2.480 408.580 6.440}}
        {VPWR {406.980 219.320 408.580 223.280}}
        {VPWR {1300.990 2.480 1302.590 6.440}}
        {VPWR {1300.990 219.320 1302.590 223.280}}
        {VPWR {1339.860 2.480 1341.460 6.440}}
        {VPWR {1339.860 219.320 1341.460 223.280}}
        {VGND {21.580 2.480 23.180 6.440}}
        {VGND {21.580 219.320 23.180 223.280}}
        {VGND {60.450 2.480 62.050 6.440}}
        {VGND {60.450 219.320 62.050 223.280}}
        {VGND {99.320 2.480 100.920 6.440}}
        {VGND {99.320 219.320 100.920 223.280}}
        {VGND {138.190 2.480 139.790 6.440}}
        {VGND {138.190 219.320 139.790 223.280}}
        {VGND {177.060 2.480 178.660 6.440}}
        {VGND {177.060 219.320 178.660 223.280}}
        {VGND {215.930 2.480 217.530 6.440}}
        {VGND {215.930 219.320 217.530 223.280}}
        {VGND {254.800 2.480 256.400 6.440}}
        {VGND {254.800 219.320 256.400 223.280}}
        {VGND {293.670 2.480 295.270 6.440}}
        {VGND {293.670 219.320 295.270 223.280}}
        {VGND {332.540 2.480 334.140 6.440}}
        {VGND {332.540 219.320 334.140 223.280}}
        {VGND {371.410 2.480 373.010 6.440}}
        {VGND {371.410 219.320 373.010 223.280}}
        {VGND {410.280 2.480 411.880 6.440}}
        {VGND {410.280 219.320 411.880 223.280}}
        {VGND {1304.290 2.480 1305.890 6.440}}
        {VGND {1304.290 219.320 1305.890 223.280}}
        {VGND {1343.160 2.480 1344.760 6.440}}
        {VGND {1343.160 219.320 1344.760 223.280}}
    }
    foreach netname {VPWR VGND} {
        set net [$block findNet $netname]
        if {$net == "NULL"} {error "Missing supply $netname"}
        set iterm [$inst findITerm $netname]
        if {$iterm == "NULL"} {error "Missing core terminal $netname"}
        $iterm connect $net
        set sw [odb::dbSWire_create $net ROUTED]
        foreach item $feeds {
            lassign $item name box
            if {$name ne $netname} {continue}
            lassign $box x1 y1 x2 y2
            odb::dbSBox_create $sw $m4 [expr {round($x1*$units)}] [expr {round($y1*$units)}] [expr {round($x2*$units)}] [expr {round($y2*$units)}] STRIPE
        }
    }
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
    # Export only the full-height M4 supply columns. The central portion is real
    # core metal, verified by scripts/expose_core_power_pins.py; top/bottom parts
    # are the feeds generated by pdn_core_feeds.tcl. No new metal crosses the core.
    set block [ord::get_db_block]
    set units [$block getDbUnitsPerMicron]
    set m4 [[ord::get_db_tech] findLayer met4]
    foreach netname {VPWR VGND} {
        set term [$block findBTerm $netname]
        if {$term eq "NULL"} {error "Missing wrapper supply terminal $netname"}
        foreach pin [$term getBPins] {odb::dbBPin_destroy $pin}
        set pin [odb::dbBPin_create $term]
        $pin setPlacementStatus FIRM
        set columns {}
        foreach item $feeds {
            lassign $item name box
            if {$name ne $netname} {continue}
            lassign $box x1 y1 x2 y2
            dict set columns [list $x1 $x2] 1
        }
        set expected 13
        if {[dict size $columns] != $expected} {error "Unexpected supply column count for $netname"}
        foreach column [dict keys $columns] {
            lassign $column x1 x2
            odb::dbBox_create $pin $m4 [expr {round($x1*$units)}] [expr {round(2.48*$units)}] \
                [expr {round($x2*$units)}] [expr {round(223.28*$units)}]
        }
    }
    tt_restore_reserved_rows
    foreach net {VPWR VGND} {check_power_grid -net $net}
}
