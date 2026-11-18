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

# Complete the standard grid with the previously verified SRAM edge feeds.
proc tt_connect_sram_power {} {
# Extend TT's vertical met4 power stripes across the placement halo to the
# OpenRAM macro's outer met3 power rings. Never route across the array interior.
set block [ord::get_db_block]
set tech [ord::get_db_tech]
set macro_name core.itf.memory.size_512.macro
set inst [$block findInst $macro_name]
if {$inst == "NULL"} {error "Expected accelerator SRAM instance $macro_name"}
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
