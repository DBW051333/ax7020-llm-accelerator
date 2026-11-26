# Recheck an unchanged routed design at a lower FCLK1. Python verifies the
# original and lower-clock HWH metadata before invoking this script.
if {[llength $argv] != 5} {
    error "Expected routed DCP, matching bit, lower-clock HWH, output dir, period"
}
lassign $argv dcp bit hwh out period
open_checkpoint $dcp
set pin [get_pins {head_quad_i/ps7/inst/PS7_i/FCLKCLK[1]}]
if {[llength $pin] != 1 || $period <= [get_property PERIOD [get_clocks clk_fpga_1]]} {
    error "Expected a strictly slower FCLK1"
}
create_clock -name clk_fpga_1 -period $period $pin
set_input_jitter [get_clocks clk_fpga_1] 0.15
report_timing_summary -file [file join $out timing.rpt]
report_clock_interaction -file [file join $out clock_interaction.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_bus_skew -file [file join $out bus_skew.rpt]
report_drc -file [file join $out drc.rpt]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup] != 1 || [llength $hold] != 1} { error "Missing timing paths" }
set wns [get_property SLACK $setup]
set whs [get_property SLACK $hold]
if {$wns < 0 || $whs < 0} { error "Timing failed WNS=$wns WHS=$whs" }
file copy $bit [file join $out head_quad_2017.bit]
file copy $hwh [file join $out head_quad_2017.hwh]
puts "REBUILD2017-PASS WNS=$wns WHS=$whs"
exit
