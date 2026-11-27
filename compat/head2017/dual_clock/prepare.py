"""Generate an isolated dual-clock build from the pinned Resident source."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

here = Path(__file__).resolve().parent
repo = here.parents[2]

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Unexpected baseline source around {old!r}")
    return text.replace(old, new)

def prepare(axi, compute, scale_pipeline, output=None):
    suffix = "-pipe" if scale_pipeline else ""
    out = output or repo / f"build/head2017/dual-clock-{axi}-{compute}{suffix}"
    subprocess.run([sys.executable, str(here.parent / "prepare_decode.py"), "--output", str(out)], check=True)
    path = out / "build_quad.tcl"
    tcl = path.read_text()
    hook = r"""
    source [file join $repo compat head2017 dual_clock topology.tcl]
    set topology [string map [list \
        {PCW_FPGA0_PERIPHERAL_FREQMHZ 83.333} {PCW_FPGA0_PERIPHERAL_FREQMHZ @AXI@} \
        {clk ps7/M_AXI_GP0_ACLK} {configure_compute_clock @CORE@
clk ps7/M_AXI_GP0_ACLK} \
        { $a/aclk} {} { $a/aresetn} {} \
        {connect_bd_intf_net [get_bd_intf_pins $d/M_AXIS_MM2S] [get_bd_intf_pins $a/s_axis]
    connect_bd_intf_net [get_bd_intf_pins $a/m_axis] [get_bd_intf_pins $d/S_AXIS_S2MM]} \
        {connect_dual_lane $i}] $topology]
    eval $topology
    check_dual_clocks @AXI@ @CORE@
"""
    tcl = replace_once(tcl, '    eval $topology', hook.replace("@AXI@", str(axi)).replace("@CORE@", str(compute)))
    tcl = replace_once(tcl, "report_drc -file", """report_clock_interaction -file [file join $out clock_interaction.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_bus_skew -file [file join $out bus_skew.rpt]
report_drc -file""")
    path.write_text(tcl)
    shutil.copyfile(here / "q58_dot32.sv", out / "rtl/q58_dot32.sv")
    if scale_pipeline:
        shutil.copyfile(here / "q58_scaled_accum.sv", out / "rtl/q58_scaled_accum.sv")
    print(out)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--axi", type=int, default=125)
    parser.add_argument("--compute", type=int, default=200)
    parser.add_argument("--scale-pipeline", action="store_true")
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    prepare(args.axi, args.compute, args.scale_pipeline, args.output)
