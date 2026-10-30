"""Verify that legacy HWH describes the intended four-DMA runtime contract."""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
out = root / 'build/vivado2017/quad-2017'
path = out / 'project/blite_quad_2017.srcs/sources_1/bd/blite_quad/hw_handoff/blite_quad.hwh'
tree = ET.parse(path).getroot()
modules = {m.get('INSTANCE'): m for m in tree.iter('MODULE')}
checks = []
def require(ok, description):
    if not ok:
        raise SystemExit(f'HANDOFF-FAIL: {description}')
    checks.append(description)

for lane in range(4):
    name = f'dma{lane}'
    require(name in modules and modules[name].get('MODTYPE')=='axi_dma',f'{name} AXI DMA')
    params = {p.get('NAME'):p.get('VALUE') for p in modules[name].iter('PARAMETER')}
    for param, value in {'C_INCLUDE_SG':0,'C_M_AXI_MM2S_DATA_WIDTH':64,'C_M_AXI_S2MM_DATA_WIDTH':64,
                         'C_M_AXIS_MM2S_TDATA_WIDTH':64,'C_S_AXIS_S2MM_TDATA_WIDTH':64}.items():
        require(int(params[param])==value,f'{name} {param}={value}')
    ranges = [m for m in tree.iter('MEMRANGE') if m.get('INSTANCE')==name and m.get('MEMTYPE')=='REGISTER']
    require(len(ranges)==1 and int(ranges[0].get('BASEVALUE'),16)==0x40400000+lane*0x10000,
            f'{name} control address')
    memory = list(modules[name].iter('MEMRANGE'))
    require(len(memory)==2 and all(m.get('SLAVEBUSINTERFACE')==f'S_AXI_HP{lane}' for m in memory),
            f'{name} both memory directions use HP{lane}')
ps = {p.get('NAME'):p.get('VALUE') for p in modules['ps7'].iter('PARAMETER')}
require(abs(float(ps['PCW_FPGA0_PERIPHERAL_FREQMHZ'])-83.333)<0.01,'FCLK0 request 83.333 MHz')
report = {'status':'HANDOFF-PASS','checks':checks,'hwh_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
(out/'handoff-audit.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
print(f'HANDOFF-PASS: {len(checks)} checks')
