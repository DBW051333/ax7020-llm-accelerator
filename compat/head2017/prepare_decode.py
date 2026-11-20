"""Build from the exact v5 sources, without changing either existing workspace."""
from pathlib import Path
import math
import shutil
import subprocess

src = Path(__file__).resolve().parent
repo = src.parents[1]
out = repo / 'build/head2017/decode'
rtl = out / 'rtl'
rtl.mkdir(parents=True, exist_ok=True)
rev = '220a6febac2df0602894cb925320676fc6455d11'
for name in ('gateup_axis.sv','q58_dot32.sv','fp_mul_rne.sv','silu_mul.sv'):
    (rtl/name).write_bytes(subprocess.check_output(
        ['git','show',f'{rev}:compat/gateup2017/rtl/{name}'],cwd=repo))
for rel in ('compat/head2017/rtl/head_lane.v','compat/head2017/rtl/decode_lane.v',
            'accel/experimental/q58_scale/q58_scaled_accum.sv'):
    shutil.copyfile(repo/rel,rtl/Path(rel).name)
head = rtl/'head_lane.v'
head.write_text(head.read_text().replace(' .sx(),', ''))
(rtl/'sigmoid.hex').write_text(''.join(
    f'{round((1/(1+math.exp(-i/256)))*(1<<30)):08x}\n' for i in range(8193)), encoding='ascii')
base = (repo/'compat/gateup2017/build_quad.tcl').read_text()
start,end=base.index('set compat_dir'),base.index('set stage')
base = base[:start] + 'set base [file dirname [file normalize [info script]]]\nset repo [file normalize [file join $base ../../..]]\nset out [file join $base quad]\nif {[info exists ::env(DECODE_BUILD_TAG)]} { set out [file join $base $::env(DECODE_BUILD_TAG)] }\nset rtl [file join $base rtl]\n' + base[end:]
base=base.replace('puts [exec python [file join $compat_dir receipt.py] --check]', '')
base=base.replace('blite_axis_top gateup_bd','blite_axis_top decode_lane')
base=base.replace('gateup_quad','head_quad')
(out/'build_quad.tcl').write_text(base)
