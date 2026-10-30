"""Load the verified legacy bit/HWH pair through PYNQ, never raw JTAG."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import struct
import time

parser = argparse.ArgumentParser()
parser.add_argument('bitfile')
parser.add_argument('--inspect-only',action='store_true')
args = parser.parse_args()
path = Path(args.bitfile).resolve()
if not path.is_file() or not path.with_suffix('.hwh').is_file():
    parser.error('Matching bit and HWH files are required')
expected = 'f5c5e2faf46ce512b58a879106f178df8afa9ac5b96853b6ee73a6a117a5310a'
digest = hashlib.sha256(path.read_bytes()).hexdigest()
if digest != expected:
    raise SystemExit('Bitstream differs from the accepted 2017.4 rebuild')
from pynq import Clocks, Overlay, PL

with open('/tmp/blite-perf.lock','a+') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    reference = Path('/sys/firmware/devicetree/base/axi/slcr@f8000000/clkc@100/ps-clk-frequency')
    reference_hz = struct.unpack('>I',reference.read_bytes())[0]
    Clocks._instance._ref_clk_mhz = reference_hz/1e6
    print('PS_REFERENCE_HZ',reference_hz,flush=True)
    print('PREVIOUS_BITFILE',PL.bitfile_name,flush=True)
    overlay = Overlay(str(path),download=False)
    for lane in range(4):
        description = overlay.ip_dict[f'dma{lane}']
        assert description['phys_addr'] == 0x40400000+lane*0x10000,description
        print('DMA_METADATA',lane,hex(description['phys_addr']),flush=True)
    print('METADATA-PASS',flush=True)
    if not args.inspect_only:
        start=time.monotonic()
        overlay.download()
        frequency=Clocks.fclk0_mhz
        if abs(frequency-83.333333)>0.05:
            raise RuntimeError(f'Unexpected FCLK0 frequency: {frequency}')
        record={'bit_sha256':digest,'fclk0_mhz':frequency,'ps_reference_hz':reference_hz,
                'elapsed_s':time.monotonic()-start,'status':'OVERLAY-LOADED'}
        path.with_name('loaded-overlay.json').write_text(json.dumps(record,indent=2)+'\n')
        print(json.dumps(record),flush=True)
