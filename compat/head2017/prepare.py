"""Prepare isolated simulation sources and adapt the audited four-HP topology."""
from pathlib import Path
import shutil

src = Path(__file__).resolve().parent
repo = src.parents[1]
out = repo / "build/head2017"
rtl = out / "rtl"
rtl.mkdir(parents=True, exist_ok=True)
for rel in (
    "compat/head2017/rtl/head_lane.v",
    "compat/gateup2017/rtl/q58_dot32.sv",
    "accel/experimental/q58_scale/q58_scaled_accum.sv",
):
    shutil.copyfile(repo / rel, rtl / Path(rel).name)
base = (repo / "compat/gateup2017/build_quad.tcl").read_text()
start = base.index("set compat_dir")
end = base.index("set stage")
base = base[:start] + 'set base [file dirname [file normalize [info script]]]\nset repo [file normalize [file join $base ../..]]\nset out [file join $base quad]\nif {[info exists ::env(HEAD_BUILD_TAG)]} { set out [file join $base $::env(HEAD_BUILD_TAG)] }\nset rtl [file join $base rtl]\n' + base[end:]
base = base.replace("puts [exec python [file join $compat_dir receipt.py] --check]", "")
base = base.replace("    add_files [file join $rtl sigmoid.hex]\n", "")
base = base.replace("blite_axis_top gateup_bd", "blite_axis_top head_lane")
base = base.replace("gateup_quad", "head_quad")
(out / "build_quad.tcl").write_text(base)
