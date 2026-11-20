"""Load a timing-accepted LM Head overlay after verifying both artifacts."""
import fcntl
import hashlib
import json
import struct
from pathlib import Path
from pynq import Clocks, Overlay

here = Path(__file__).resolve().parent
receipt = json.loads((here/'accepted.json').read_text())
assert receipt['wns_ns'] >= 0 and receipt['whs_ns'] >= 0
for name in ('head_quad_2017.bit', 'head_quad_2017.hwh'):
    assert hashlib.sha256((here/name).read_bytes()).hexdigest() == receipt['files'][name]
with open('/tmp/blite-perf.lock', 'a+') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    freq = Path('/sys/firmware/devicetree/base/axi/slcr@f8000000/clkc@100/ps-clk-frequency')
    Clocks._instance._ref_clk_mhz = struct.unpack('>I', freq.read_bytes())[0] / 1e6
    overlay = Overlay(str(here/'head_quad_2017.bit'), download=False)
    for i in range(4):
        assert overlay.ip_dict[f'dma{i}']['phys_addr'] == 0x40400000+i*0x10000
    overlay.download()
    assert abs(Clocks.fclk0_mhz - 83.333333) < 0.05
    print('HEAD-LOADED', Clocks.fclk0_mhz, receipt, flush=True)
