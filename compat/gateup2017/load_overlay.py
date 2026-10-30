"""Load only a timing-accepted artifact pair, holding the shared board lock."""
import fcntl,hashlib,json,struct
from pathlib import Path
from pynq import Overlay,Clocks,PL
base=Path(__file__).resolve().parent/'overlay'
accepted=json.loads((base/'accepted.json').read_text())
assert accepted['wns_ns']>=0 and accepted['whs_ns']>=0
for name,digest in accepted['files'].items():
    assert hashlib.sha256((base/name).read_bytes()).hexdigest()==digest,name
with open('/tmp/blite-perf.lock','a+') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    reference=Path('/sys/firmware/devicetree/base/axi/slcr@f8000000/clkc@100/ps-clk-frequency')
    Clocks._instance._ref_clk_mhz=struct.unpack('>I',reference.read_bytes())[0]/1e6
    path=base/'gateup_quad_2017.bit'
    overlay=Overlay(str(path),download=False)
    for i in range(4): assert overlay.ip_dict[f'dma{i}']['phys_addr']==0x40400000+i*0x10000
    print('PREVIOUS_BITFILE',PL.bitfile_name,flush=True)
    overlay.download()
    assert abs(Clocks.fclk0_mhz-83.333333)<0.05
    result=dict(status='GATEUP-OVERLAY-LOADED',fclk0_mhz=Clocks.fclk0_mhz,accepted=accepted)
    (base/'loaded.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result),flush=True)
