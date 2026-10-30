"""Check generated AXIS wiring, constant byte enables and HP ID padding."""
from pathlib import Path
import hashlib
import json
import re

root = Path(__file__).resolve().parents[2]
out = root / 'build/vivado2017/quad-2017'
bd = out / 'project/blite_quad_2017.srcs/sources_1/bd/blite_quad'
netlist = bd / 'synth/blite_quad.v'
text = netlist.read_text(encoding='utf8')
checks = []

def ports(instance):
    match = re.search(r'\bblite_quad_\w+\s+'+re.escape(instance)+r'\s*\((.*?)\);', text, re.S)
    if not match:
        raise SystemExit(f'Cannot find instance: {instance}')
    return dict(re.findall(r'\.(\w+)\(([^()]*)\)', match.group(1)))

def require(ok, message):
    if not ok:
        raise SystemExit(f'NETLIST-FAIL: {message}')
    checks.append(message)

ps = ports('ps7')
for lane in range(4):
    dma, accel = ports(f'dma{lane}'), ports(f'accel{lane}')
    for suffix in ['tdata','tvalid','tready','tlast']:
        require(dma['m_axis_mm2s_'+suffix] == accel['s_axis_'+suffix], f'lane {lane} input {suffix}')
        require(dma['s_axis_s2mm_'+suffix] == accel['m_axis_'+suffix], f'lane {lane} output {suffix}')
    for signal in [dma['m_axis_mm2s_tdata'], dma['s_axis_s2mm_tdata']]:
        require(re.search(r'wire\s+\[63:0\]\s*'+re.escape(signal)+r'\s*;',text) is not None,
                f'lane {lane} 64-bit data {signal}')
    require(dma['s_axis_s2mm_tkeep'] == f'keep{lane}_dout',f'lane {lane} TKEEP constant net')
    constant = (bd/f'ip/blite_quad_keep{lane}_0/sim/blite_quad_keep{lane}_0.v').read_text()
    require('.CONST_WIDTH(8)' in constant and ".CONST_VAL('HFF)" in constant,f'lane {lane} TKEEP=0xff')
    for signal in ['AWID','ARID','WID']:
        expected = "{1'b0,1'b0,1'b0,1'b0,1'b0,hp_ic"+str(lane)+'_M00_AXI_'+signal+'}'
        require(ps[f'S_AXI_HP{lane}_{signal}'] == expected,f'HP{lane} {signal} zero extension')
    require(ps[f'S_AXI_HP{lane}_ACLK'] == 'ps7_FCLK_CLK0',f'HP{lane} common clock')

report = {'status':'NETLIST-PASS', 'checks':checks,
          'netlist_sha256':hashlib.sha256(netlist.read_bytes()).hexdigest()}
(out/'netlist-audit.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
print(f'NETLIST-PASS: {len(checks)} checks; report {out / "netlist-audit.json"}')
