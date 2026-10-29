# Rebuild the delivered four-instance design with Vivado 2017.4.
# Usage: vivado -mode batch -source .../build_quad.tcl -tclargs bd|impl|all
set compat_dir [file dirname [file normalize [info script]]]
set repo [file normalize [file join $compat_dir ../..]]
set out [file join $repo build vivado2017 quad-2017]
set rtl [file join $repo build vivado2017 rtl]
set stage [lindex $argv 0]
if {$stage eq ""} { set stage all }
if {$stage ni {bd impl all}} { error "Expected stage bd, impl or all" }
if {[version -short] ne "2017.4"} { error "This compatibility flow requires Vivado 2017.4" }
puts [exec python [file join $compat_dir verification_receipt.py] --check]
file mkdir $out
cd $out
set project [file join $out project blite_quad_2017.xpr]
if {$stage eq "impl"} {
    open_project $project
} else {
    if {[file exists $project]} { error "Project already exists; use stage impl to continue or choose a new output directory" }
    create_project blite_quad_2017 [file join $out project] -part xc7z020clg400-2
    set_property target_language Verilog [current_project]
    add_files [list [file join $rtl fpu32.v] [file join $rtl blite_core.v] [file join $rtl blite_axis_top.v]]
    create_bd_design blite_quad
    set n 4
    # Reuse the delivered topology, register map and stream integrity gates.
    set f [open [file join $repo accel rtl bd_dma_quad.tcl] r]
    set original [read $f]
    close $f
    set begin [string first {set ps [} $original]
    set end [string first {save_bd_design} $original]
    if {$begin < 0 || $end < $begin} { error "Unrecognized delivery Tcl layout" }
    set topology [string range $original $begin [expr {$end-1}]]
    # In 2017.4 DMA propagates S2MM stream width from the connected interface;
    # setting the parameter directly is read-only and scalar wiring breaks its
    # post-propagation procedure. Preserve the same wires via AXIS interfaces.
    set topology [string map [list {CONFIG.c_s_axis_s2mm_tdata_width 64} {}] $topology]
    set wire_begin [string first {    foreach {src dst}} $topology]
    set wire_end [string first {    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant} $topology]
    if {$wire_begin<0 || $wire_end<$wire_begin} { error "Unrecognized stream wiring block" }
    set streams {    connect_bd_intf_net [get_bd_intf_pins $d/M_AXIS_MM2S] [get_bd_intf_pins $a/s_axis]
    connect_bd_intf_net [get_bd_intf_pins $a/m_axis] [get_bd_intf_pins $d/S_AXIS_S2MM]
}
    set topology [string replace $topology $wire_begin [expr {$wire_end-1}] $streams]
    set topology [string map [list {validate_bd_design} {make_bd_intf_pins_external [get_bd_intf_pins ps7/DDR]
make_bd_intf_pins_external [get_bd_intf_pins ps7/FIXED_IO]
validate_bd_design}] $topology]
    proc stream_connected {path} {
        set pin [get_bd_pins $path]
        if {[llength [get_bd_nets -quiet -of_objects $pin]]==1} { return 1 }
        if {[regexp {^dma([0-3])/(m_axis_mm2s|s_axis_s2mm)_} $path -> lane direction]} {
            if {$direction eq "m_axis_mm2s"} {
                set a dma$lane/M_AXIS_MM2S; set b accel$lane/s_axis
            } else { set a dma$lane/S_AXIS_S2MM; set b accel$lane/m_axis }
        } elseif {[regexp {^accel([0-3])/(s_axis|m_axis)_} $path -> lane direction]} {
            if {$direction eq "s_axis"} {
                set a dma$lane/M_AXIS_MM2S; set b accel$lane/s_axis
            } else { set a dma$lane/S_AXIS_S2MM; set b accel$lane/m_axis }
        } else { return 0 }
        set an [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $a]]
        set bn [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $b]]
        return [expr {[llength $an]==1 && $an eq $bn}]
    }
    set topology [string map [list \
        {[llength [get_bd_nets -of_objects $pin]]} {[stream_connected $p]} \
        {[llength [get_bd_nets -of_objects [get_bd_pins $p]]]} {[stream_connected $p]}] $topology]
    eval $topology
    validate_bd_design
    save_bd_design
    generate_target all [get_files blite_quad.bd]
    make_wrapper -files [get_files blite_quad.bd] -top -import
    set_property top blite_quad_wrapper [current_fileset]
    update_compile_order -fileset sources_1
    puts "BD2017-PASS"
    if {$stage eq "bd"} { close_project; exit }
}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation incomplete: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_timing_summary -file [file join $out timing.rpt]
report_utilization -file [file join $out utilization.rpt]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup]!=1 || [llength $hold]!=1} { error "Missing timing paths" }
if {[get_property SLACK $setup]<0 || [get_property SLACK $hold]<0} {
    error "Timing failed; no accepted hardware export"
}
set run_dir [get_property DIRECTORY [get_runs impl_1]]
file copy -force [file join $run_dir blite_quad_wrapper.bit] [file join $out blite_quad_2017.bit]
set hwh [get_files -all -quiet *.hwh]
if {[llength $hwh]!=1} {
    set hwh [glob -nocomplain [file join $out project blite_quad_2017.srcs sources_1 bd blite_quad hw_handoff *.hwh]]
}
if {[llength $hwh]!=1} { error "Expected one HWH, found $hwh" }
file copy -force [lindex $hwh 0] [file join $out blite_quad_2017.hwh]
write_hwdef -force [file join $out blite_quad_2017.hwdef]
write_sysdef -force -hwdef [file join $out blite_quad_2017.hwdef] \
    -bitfile [file join $out blite_quad_2017.bit] [file join $out blite_quad_2017.hdf]
puts "REBUILD2017-PASS WNS=[get_property SLACK $setup] WHS=[get_property SLACK $hold]"
close_project
exit
