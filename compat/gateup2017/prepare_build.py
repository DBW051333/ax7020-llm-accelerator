from pathlib import Path
root=Path(__file__).resolve().parents[2]
s=(root/'compat/vivado2017/build_quad.tcl').read_text()
s=s.replace('build vivado2017 quad-2017','build gateup2017 quad-2017').replace('build vivado2017 rtl','build gateup2017 rtl')
s=s.replace('verification_receipt.py','receipt.py')
s=s.replace('set rtl [file join $repo build gateup2017 rtl]',
'''if {[info exists ::env(GATEUP_BUILD_TAG)]} {
    set out [file join $repo build gateup2017 $::env(GATEUP_BUILD_TAG)]
}
set rtl [file join $repo build gateup2017 rtl]''')
s=s.replace('blite_quad_2017','gateup_quad_2017').replace('blite_quad','gateup_quad')
s=s.replace('add_files [list [file join $rtl fpu32.v] [file join $rtl blite_core.v] [file join $rtl blite_axis_top.v]]',
'''add_files [glob [file join $rtl *.sv] [file join $rtl *.v]]
    add_files [file join $rtl sigmoid.hex]''')
s=s.replace('    eval $topology','    set topology [string map [list blite_axis_top gateup_bd] $topology]\n    eval $topology')
s=s.replace('report_utilization -file [file join $out utilization.rpt]',
'''report_utilization -file [file join $out utilization.rpt]
report_drc -file [file join $out drc.rpt]''')
(root/'compat/gateup2017/build_quad.tcl').write_text(s)
print('Build script prepared')
