"""Generate the combined Para-MAC and Resident overlay in an isolated build."""
import argparse
from pathlib import Path
import subprocess
import sys

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--compute', type=int, choices=(83, 100), default=100)
args = parser.parse_args()
tag = 'para-mac' if args.compute == 100 else 'para-mac-83'
out = here.parents[2] / 'build/head2017' / tag
if out.exists():
    raise SystemExit(f'Use a fresh build directory: {out}')
subprocess.run([sys.executable, str(here.parent / 'dual_clock/prepare.py'),
                '--axi', '125', '--compute', str(args.compute), '--scale-pipeline',
                '--output', str(out)], check=True)
rtl = out / 'rtl'
(rtl / 'para_mac_lane.sv').write_text((here / 'decode_lane.sv').read_text().replace(
    'module decode_lane', 'module para_mac_lane').replace('parameter COLUMNS = 2', 'parameter COLUMNS = 1'))
path = rtl / 'decode_lane.v'
source = path.read_text()
changes = {
    'reg active, head;': 'reg active, head, para;\n    wire para_header = !active && s_axis_tdata == 64\'h3143414d3451;\n    wire para_in_ready, para_valid, para_last;\n    wire [63:0] para_data;',
    'assign s_axis_tready = use_head ? head_in_ready : gate_in_ready;':
        'assign s_axis_tready = para_header ? 1\'b1 : para ? para_in_ready : use_head ? head_in_ready : gate_in_ready;',
    'assign m_axis_tdata = head ?': 'assign m_axis_tdata = para ? para_data : head ?',
    '(head ? head_valid : gate_valid)': '(para ? para_valid : head ? head_valid : gate_valid)',
    'assign m_axis_tlast = head ?': 'assign m_axis_tlast = para ? para_last : head ?',
    'active<=0; head<=0;': 'active<=0; head<=0; para<=0;',
    'else if (irq) active<=0;': 'else if (irq) begin active<=0; para<=0; end',
    'active<=1; head<=use_head;': 'active<=1; head<=use_head; para<=para_header;',
    's_axis_tvalid && use_head': 's_axis_tvalid && use_head && !para && !para_header',
    's_axis_tvalid && !use_head': 's_axis_tvalid && !use_head && !para && !para_header',
    'active && !head && m_axis_tready': 'active && !head && !para && m_axis_tready',
    'endmodule': '''    para_mac_lane para_engine(aclk,aresetn,s_axis_tdata,s_axis_tvalid && para,s_axis_tlast,
        para_in_ready,para_data,para_valid,para_last,para && m_axis_tready,);
endmodule''',
}
for original, modified in changes.items():
    if source.count(original) != 1:
        raise ValueError(f'Unexpected source at {original!r}')
    source = source.replace(original, modified)
path.write_text(source)
