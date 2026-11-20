# Copyright 2025 LibreLane Contributors
#
# Adapted from OpenLane
#
# Copyright 2020-2022 Efabless Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET)} {
        lappend secondary $vdd

        set db_net [[ord::get_db_block] findNet $vdd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }

    if { $gnd != $::env(GND_NET)} {
        lappend secondary $gnd

        set db_net [[ord::get_db_block] findNet $gnd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary



if { $::env(PDN_MULTILAYER) == 1 } {

    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
    }

    define_pdn_grid \
        -name stdcell_grid \
        -starts_with POWER \
        -voltage_domain CORE \
        {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_HORIZONTAL_LAYER) \
        -width $::env(PDN_HWIDTH) \
        -pitch $::env(PDN_HPITCH) \
        -offset $::env(PDN_HOFFSET) \
        -spacing $::env(PDN_HSPACING) \
        -starts_with POWER \
        {*}$arg_list

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
} else {

    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER)"
    }

    define_pdn_grid \
        -name stdcell_grid \
        -starts_with POWER \
        -voltage_domain CORE \
        {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list
}

# Adds the standard cell rails if enabled.
if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
}


# Adds the core ring if enabled.
if { $::env(PDN_CORE_RING) == 1 } {
    if { $::env(PDN_MULTILAYER) == 1 } {
        set arg_list [list]
        append_if_flag arg_list PDN_CORE_RING_ALLOW_OUT_OF_DIE -allow_out_of_die
        append_if_flag arg_list PDN_CORE_RING_CONNECT_TO_PADS -connect_to_pads
        append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

        set pdn_core_vertical_layer $::env(PDN_VERTICAL_LAYER)
        set pdn_core_horizontal_layer $::env(PDN_HORIZONTAL_LAYER)

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            set pdn_core_vertical_layer $::env(PDN_CORE_VERTICAL_LAYER)
        }

        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            set pdn_core_horizontal_layer $::env(PDN_CORE_HORIZONTAL_LAYER)
        }

        add_pdn_ring \
            -grid stdcell_grid \
            -layers "$pdn_core_vertical_layer $pdn_core_horizontal_layer" \
            -widths "$::env(PDN_CORE_RING_VWIDTH) $::env(PDN_CORE_RING_HWIDTH)" \
            -spacings "$::env(PDN_CORE_RING_VSPACING) $::env(PDN_CORE_RING_HSPACING)" \
            -core_offset "$::env(PDN_CORE_RING_VOFFSET) $::env(PDN_CORE_RING_HOFFSET)" \
            {*}$arg_list

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
        }

        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_HORIZONTAL_LAYER) $::env(PDN_VERTICAL_LAYER)"
        }

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] && [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_CORE_HORIZONTAL_LAYER)"
        }

    } else {
        throw APPLICATION "PDN_CORE_RING cannot be used when PDN_MULTILAYER is set to false."
    }
}


# The SRAM uses explicit edge connections from pdn_sram_connections.tcl.
# Do not add automatic macro M3/M4 vias: the macro already contains them.

# Complete the standard grid with geometry-derived SRAM side feeds.
# Integrated PDN DRC/connectivity must be rerun for this new placement.
# Include generated via landing pads when checking feed-to-supply shorts.
proc tt_pdn_m3_rectangles {sw} {
    set rectangles {}
    foreach box [$sw getWires] {
        if {[$box isVia]} {
            lassign [$box getViaXY] vx vy
            set via [$box getBlockVia]
            if {$via == "NULL"} {set via [$box getTechVia]}
            foreach pad [$via getBoxes] {
                if {[[$pad getTechLayer] getName] == "met3"} {
                    lappend rectangles [list [expr {$vx+[$pad xMin]}] [expr {$vy+[$pad yMin]}] \
                        [expr {$vx+[$pad xMax]}] [expr {$vy+[$pad yMax]}]]
                }
            }
        } elseif {[[$box getTechLayer] getName] == "met3"} {
            lappend rectangles [list [$box xMin] [$box yMin] [$box xMax] [$box yMax]]
        }
    }
    return $rectangles
}

proc tt_connect_sram_power {} {
# Right-side, unrotated SRAM: feed its horizontal M3 rings from full-height
# M4 stripes in the logic region to the left. No top/bottom halo is required.
set block [ord::get_db_block]
set tech [ord::get_db_tech]
if {[$block getDbUnitsPerMicron] != 1000} {error "SRAM PG expects SKY130 1000 DBU/um"}
set macro_name core.itf.memory.size_1k.macro
set inst [$block findInst $macro_name]
if {$inst == "NULL"} {error "Expected accelerator SRAM instance $macro_name"}
if {[$inst getOrient] ni {R0 N}} {error "SRAM side feeds require unrotated placement"}
set bbox [$inst getBBox]
set mx1 [$bbox xMin];set my1 [$bbox yMin]
set mx2 [$bbox xMax];set my2 [$bbox yMax]
set m3 [$tech findLayer met3]
set m4 [$tech findLayer met4]
set via "NULL"
foreach candidate [$block getVias] {
    set layers {};set fits 1
    foreach box [$candidate getBoxes] {
        set layer [$box getTechLayer]
        if {[$layer getRoutingLevel] > 0} {
            lappend layers [$layer getName]
            if {[$box getDX] > 1600 || [$box getDY] > 1740} {set fits 0}
        }
    }
    if {$fits && [lsort -unique $layers] == {met3 met4}} {set via $candidate;break}
}
if {$via == "NULL"} {error "No legal met3/met4 via fits SRAM side feeds"}
foreach {netname pinname} {VPWR vccd1 VGND vssd1} {
    set net [$block findNet $netname]
    set iterm [$inst findITerm $pinname]
    if {$net == "NULL" || $iterm == "NULL"} {error "Missing SRAM supply $pinname"}
    set rings {}
    foreach mpin [[$iterm getMTerm] getMPins] {
        foreach box [$mpin getGeometry] {
            if {[[$box getTechLayer] getName] == "met3" && [$box getDX] > ($mx2-$mx1)/2} {
                lappend rings [list [expr {$mx1+[$box xMin]}] [expr {$my1+[$box yMin]}] [expr {$my1+[$box yMax]}]]
            }
        }
    }
    if {[llength $rings] != 2} {error "Expected two horizontal $pinname rings"}
    set ymin $my2;set ymax $my1
    foreach ring $rings {lassign $ring rx ry1 ry2;set ymin [expr {min($ymin,$ry1)}];set ymax [expr {max($ymax,$ry2)}]}
    set best {};set best_x -1
    foreach sw [$net getSWires] {
        foreach box [$sw getWires] {
            if {![$box isVia] && [[$box getTechLayer] getName] == "met4" &&
                [$box xMax] < $mx1 && [$box yMin] <= $ymin && [$box yMax] >= $ymax && [$box xMax] > $best_x} {
                set best [list [$box xMin] [$box xMax]];set best_x [$box xMax]
            }
        }
    }
    if {[llength $best] == 0} {error "No full-height $netname stripe to the left of SRAM"}
    lassign $best x1 x2
    set cx [expr {($x1+$x2)/2}]
    set sw [odb::dbSWire_create $net ROUTED]
    set side_feeds($netname) $sw
    foreach ring $rings {
        lassign $ring rx ry1 ry2
        set cy [expr {($ry1+$ry2)/2}]
        # The lower VPWR feed has a narrow gap to its own row-via pad.
        # Bridge that same-net gap; shifting this feed upward would short the
        # neighboring VGND pad. Only the upper feed needs an inward jog.
        set dy 0
        if {$netname eq "VPWR" && $cy > ($my1+$my2)/2} {set dy -600}
        if {$dy == 0} {
            odb::dbSBox_create $sw $m3 $x1 $ry1 [expr {$rx+1740}] $ry2 STRIPE
        } else {
            set fy1 [expr {$ry1+$dy}];set fy2 [expr {$ry2+$dy}]
            set bend [expr {$x2+5680}]
            if {$bend+1740 >= $rx} {error "Insufficient room for SRAM PG jog"}
            odb::dbSBox_create $sw $m3 $x1 $fy1 [expr {$bend+1740}] $fy2 STRIPE
            odb::dbSBox_create $sw $m3 $bend [expr {min($ry1,$fy1)}] \
                [expr {$bend+1740}] [expr {max($ry2,$fy2)}] STRIPE
            odb::dbSBox_create $sw $m3 $bend $ry1 [expr {$rx+1740}] $ry2 STRIPE
        }
        odb::dbSBox_create $sw $via $cx [expr {$cy+$dy}] STRIPE
        if {$netname eq "VPWR" && $cy < ($my1+$my2)/2} {
            set pad {};set pad_top -1
            foreach wire [$net getSWires] {
                foreach box [$wire getWires] {
                    if {![$box isVia] && [[$box getTechLayer] getName] == "met3" &&
                        [$box xMin] >= $x1 && [$box xMax] <= $x2 &&
                        [$box yMax] <= $ry1 && $ry1-[$box yMax] < 600 &&
                        [$box yMax] > $pad_top} {
                        set pad [list [$box xMin] [$box yMin] [$box xMax]]
                        set pad_top [$box yMax]
                    }
                }
            }
            if {[llength $pad] == 0} {error "Missing VPWR row-via pad for lower feed bridge"}
            lassign $pad px1 py1 px2
            odb::dbSBox_create $sw $m3 $px1 $py1 $px2 [expr {$ry1+300}] STRIPE
        }
    }
    puts "SRAM PDN: $netname uses left stripe at $cx DBU"
}

# check_power_grid proves each supply connected but does not detect a
# physical bridge between supplies. Reject such a bridge before placement.
foreach {name other} {VPWR VGND VGND VPWR} {
    set obstacles {}
    foreach sw [[$block findNet $other] getSWires] {
        lappend obstacles {*}[tt_pdn_m3_rectangles $sw]
    }
    foreach rect [tt_pdn_m3_rectangles $side_feeds($name)] {
        lassign $rect ax1 ay1 ax2 ay2
        foreach obstacle $obstacles {
            lassign $obstacle bx1 by1 bx2 by2
            if {max($ax1,$bx1) <= min($ax2,$bx2) &&
                max($ay1,$by1) <= min($ay2,$by2)} {
                error "SRAM PG short: $name M3 $rect touches $other M3 $obstacle"
            }
        }
    }
}
puts "SRAM PDN: no M3 feed overlap between VPWR and VGND (including via pads)"

# Only continuous full-height M4 straps are external power access pins.
# Short stripe pieces above/below the SRAM are internal PDN conductors, not
# independent top-level ports. Keep every SWire/metal shape and its connection.
set die [$block getDieArea]
set edge_margin 10000
foreach name {VPWR VGND} {
    set term [$block findBTerm $name]
    if {$term == "NULL"} {error "Missing supply terminal $name"}
    set keep {}
    set removed 0
    set old_pins [$term getBPins]
    foreach pin $old_pins {
        foreach box [$pin getBoxes] {
            if {[[$box getTechLayer] getName] != "met4"} {
                error "Unexpected $name pin layer"
            }
            if {[$box yMin] <= [$die yMin]+$edge_margin &&
                [$box yMax] >= [$die yMax]-$edge_margin} {
                lappend keep [list [$box xMin] [$box yMin] [$box xMax] [$box yMax]]
            } else {
                incr removed
            }
        }
    }
    if {[llength $keep] == 0} {error "No full-height external power access for $name"}
    foreach pin $old_pins {odb::dbBPin_destroy $pin}
    set pin [odb::dbBPin_create $term]
    $pin setPlacementStatus FIRM
    foreach rect $keep {
        lassign $rect x1 y1 x2 y2
        odb::dbBox_create $pin $m4 $x1 $y1 $x2 $y2
    }
    puts "SRAM PDN: $name exports [llength $keep] full-height straps; $removed short pieces remain internal"
}

}
rename pdngen tt_sram_standard_pdngen
proc pdngen {args} {
    uplevel 1 [list tt_sram_standard_pdngen {*}$args]
    tt_connect_sram_power
}
