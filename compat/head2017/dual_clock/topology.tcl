proc configure_compute_clock {mhz} {
    set_property -dict [list CONFIG.PCW_EN_CLK1_PORT 1 \
        CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ $mhz] [get_bd_cells ps7]
    set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_compute]
    connect_bd_net [get_bd_pins ps7/FCLK_CLK1] [get_bd_pins $rst/slowest_sync_clk]
    connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins $rst/ext_reset_in]
}

proc add_crossing {name source sink srcclk dstclk srcrst dstrst} {
    set fifo [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:1.1 $name]
    # Word mode forwards descriptor TLAST without waiting for an entire packet.
    set_property -dict [list CONFIG.IS_ACLK_ASYNC 1 CONFIG.TDATA_NUM_BYTES 8 \
        CONFIG.HAS_TLAST 1 CONFIG.FIFO_MODE 1 CONFIG.FIFO_DEPTH 32 \
        CONFIG.SYNCHRONIZATION_STAGES 3] $fifo
    foreach {pin driver} [list s_axis_aclk $srcclk m_axis_aclk $dstclk \
                               s_axis_aresetn $srcrst m_axis_aresetn $dstrst] {
        connect_bd_net [get_bd_pins $driver] [get_bd_pins $name/$pin]
    }
    connect_bd_intf_net [get_bd_intf_pins $source] [get_bd_intf_pins $name/S_AXIS]
    connect_bd_intf_net [get_bd_intf_pins $name/M_AXIS] [get_bd_intf_pins $sink]
}

proc connect_dual_lane {lane} {
    set a accel$lane
    set d dma$lane
    set io ps7/FCLK_CLK0
    set core ps7/FCLK_CLK1
    set io_reset rst0/peripheral_aresetn
    set core_reset rst_compute/peripheral_aresetn
    connect_bd_net [get_bd_pins $core] [get_bd_pins $a/aclk]
    connect_bd_net [get_bd_pins $core_reset] [get_bd_pins $a/aresetn]
    add_crossing ingress$lane $d/M_AXIS_MM2S $a/s_axis $io $core $io_reset $core_reset
    add_crossing egress$lane $a/m_axis $d/S_AXIS_S2MM $core $io $core_reset $io_reset
}

proc stream_connected {path} {
    if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $path]]] == 1} { return 1 }
    if {![regexp {^(dma|accel)([0-3])/(m_axis_mm2s|s_axis_s2mm|s_axis|m_axis)_} $path -> cell lane port]} {
        return 0
    }
    switch $port {
        m_axis_mm2s { set a dma$lane/M_AXIS_MM2S; set b ingress$lane/S_AXIS }
        s_axis_s2mm { set a dma$lane/S_AXIS_S2MM; set b egress$lane/M_AXIS }
        s_axis { set a accel$lane/s_axis; set b ingress$lane/M_AXIS }
        m_axis { set a accel$lane/m_axis; set b egress$lane/S_AXIS }
    }
    set an [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $a]]
    set bn [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $b]]
    return [expr {[llength $an] == 1 && $an eq $bn}]
}

proc check_dual_clocks {axi compute} {
    foreach {index expected} [list 0 $axi 1 $compute] {
        set actual [get_property CONFIG.FREQ_HZ [get_bd_pins ps7/FCLK_CLK$index]]
        if {abs($actual - 1000000.0*$expected) > 0.5e6} {
            error "FCLK$index generated $actual Hz; expected $expected MHz"
        }
        puts "DUAL-CLOCK FCLK$index $actual Hz"
    }
    for {set i 0} {$i < 4} {incr i} {
        foreach {pin index} [list dma$i/m_axi_mm2s_aclk 0 dma$i/m_axi_s2mm_aclk 0 \
                ps7/S_AXI_HP${i}_ACLK 0 accel$i/aclk 1 ingress$i/s_axis_aclk 0 \
                ingress$i/m_axis_aclk 1 egress$i/s_axis_aclk 1 egress$i/m_axis_aclk 0] {
            set target [get_bd_nets -of_objects [get_bd_pins ps7/FCLK_CLK$index]]
            if {[get_bd_nets -of_objects [get_bd_pins $pin]] ne $target} {
                error "Unexpected clock on $pin"
            }
        }
    }
}
