puts "PROBE_VERSION [version -short]"
create_project -in_memory -part xc7z020clg400-2
foreach ip {processing_system7 axi_dma axi_interconnect proc_sys_reset xlconstant} {
    puts "PROBE_IP $ip [get_ipdefs -all -filter NAME==$ip]"
}
foreach cmd {write_hw_platform write_hwdef write_sysdef} {
    puts "PROBE_COMMAND $cmd [info commands $cmd]"
}
exit
