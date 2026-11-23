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
        {VGND {1343.16 2.48 1344.76 6.44}}
        {VGND {1343.16 219.32 1344.76 223.28}}
        {VGND {1304.29 2.48 1305.89 6.44}}
        {VGND {1304.29 219.32 1305.89 223.28}}
        {VGND {1265.42 2.48 1267.02 6.44}}
        {VGND {1265.42 219.32 1267.02 223.28}}
        {VGND {1226.55 2.48 1228.15 6.44}}
        {VGND {1226.55 219.32 1228.15 223.28}}
        {VGND {1187.68 2.48 1189.28 6.44}}
        {VGND {1187.68 219.32 1189.28 223.28}}
        {VGND {1148.81 2.48 1150.41 6.44}}
        {VGND {1148.81 219.32 1150.41 223.28}}
        {VGND {1109.94 2.48 1111.54 6.44}}
        {VGND {1109.94 219.32 1111.54 223.28}}
        {VGND {1071.07 2.48 1072.67 6.44}}
        {VGND {1071.07 219.32 1072.67 223.28}}
        {VGND {1032.2 2.48 1033.8 6.44}}
        {VGND {1032.2 219.32 1033.8 223.28}}
        {VGND {993.33 2.48 994.93 6.44}}
        {VGND {993.33 219.32 994.93 223.28}}
        {VGND {954.46 2.48 956.06 6.44}}
        {VGND {954.46 219.32 956.06 223.28}}
        {VGND {371.41 2.48 373.01 6.44}}
        {VGND {371.41 219.32 373.01 223.28}}
        {VGND {332.54 2.48 334.14 6.44}}
        {VGND {332.54 219.32 334.14 223.28}}
        {VGND {293.67 2.48 295.27 6.44}}
        {VGND {293.67 219.32 295.27 223.28}}
        {VGND {254.8 2.48 256.4 6.44}}
        {VGND {254.8 219.32 256.4 223.28}}
        {VGND {215.93 2.48 217.53 6.44}}
        {VGND {215.93 219.32 217.53 223.28}}
        {VGND {177.06 2.48 178.66 6.44}}
        {VGND {177.06 219.32 178.66 223.28}}
        {VGND {138.19 2.48 139.79 6.44}}
        {VGND {138.19 219.32 139.79 223.28}}
        {VGND {99.32 2.48 100.92 6.44}}
        {VGND {99.32 219.32 100.92 223.28}}
        {VGND {60.45 2.48 62.05 6.44}}
        {VGND {60.45 219.32 62.05 223.28}}
        {VGND {21.58 2.48 23.18 6.44}}
        {VGND {21.58 219.32 23.18 223.28}}
        {VPWR {1339.86 2.48 1341.46 6.44}}
        {VPWR {1339.86 219.32 1341.46 223.28}}
        {VPWR {1300.99 2.48 1302.59 6.44}}
        {VPWR {1300.99 219.32 1302.59 223.28}}
        {VPWR {1262.12 2.48 1263.72 6.44}}
        {VPWR {1262.12 219.32 1263.72 223.28}}
        {VPWR {1223.25 2.48 1224.85 6.44}}
        {VPWR {1223.25 219.32 1224.85 223.28}}
        {VPWR {1184.38 2.48 1185.98 6.44}}
        {VPWR {1184.38 219.32 1185.98 223.28}}
        {VPWR {1145.51 2.48 1147.11 6.44}}
        {VPWR {1145.51 219.32 1147.11 223.28}}
        {VPWR {1106.64 2.48 1108.24 6.44}}
        {VPWR {1106.64 219.32 1108.24 223.28}}
        {VPWR {1067.77 2.48 1069.37 6.44}}
        {VPWR {1067.77 219.32 1069.37 223.28}}
        {VPWR {1028.9 2.48 1030.5 6.44}}
        {VPWR {1028.9 219.32 1030.5 223.28}}
        {VPWR {990.03 2.48 991.63 6.44}}
        {VPWR {990.03 219.32 991.63 223.28}}
        {VPWR {951.16 2.48 952.76 6.44}}
        {VPWR {951.16 219.32 952.76 223.28}}
        {VPWR {406.98 2.48 408.58 6.44}}
        {VPWR {406.98 219.32 408.58 223.28}}
        {VPWR {368.11 2.48 369.71 6.44}}
        {VPWR {368.11 219.32 369.71 223.28}}
        {VPWR {329.24 2.48 330.84 6.44}}
        {VPWR {329.24 219.32 330.84 223.28}}
        {VPWR {290.37 2.48 291.97 6.44}}
        {VPWR {290.37 219.32 291.97 223.28}}
        {VPWR {251.5 2.48 253.1 6.44}}
        {VPWR {251.5 219.32 253.1 223.28}}
        {VPWR {212.63 2.48 214.23 6.44}}
        {VPWR {212.63 219.32 214.23 223.28}}
        {VPWR {173.76 2.48 175.36 6.44}}
        {VPWR {173.76 219.32 175.36 223.28}}
        {VPWR {134.89 2.48 136.49 6.44}}
        {VPWR {134.89 219.32 136.49 223.28}}
        {VPWR {96.02 2.48 97.62 6.44}}
        {VPWR {96.02 219.32 97.62 223.28}}
        {VPWR {57.15 2.48 58.75 6.44}}
        {VPWR {57.15 219.32 58.75 223.28}}
        {VPWR {18.28 2.48 19.88 6.44}}
        {VPWR {18.28 219.32 19.88 223.28}}
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
    # Left-side M4 columns are continuous. The SRAM interrupts columns on
    # the right, where the wrapper exposes the two existing edge feeds.
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
        set expected [expr {$netname eq "VPWR" ? 22 : 21}]
        if {[dict size $columns] != $expected} {error "Unexpected supply column count for $netname"}
        foreach column [dict keys $columns] {
            lassign $column x1 x2
            set spans {{2.48 6.44} {219.32 223.28}}
            if {$x2 < 842.26} {set spans {{2.48 223.28}}}
            foreach span $spans {
                lassign $span y1 y2
                set box [list [expr {round($x1*$units)}] [expr {round($y1*$units)}] [expr {round($x2*$units)}] [expr {round($y2*$units)}]]
                odb::dbBox_create $pin $m4 {*}$box
            }
        }
    }
    tt_restore_reserved_rows
    foreach net {VPWR VGND} {check_power_grid -net $net}
}
