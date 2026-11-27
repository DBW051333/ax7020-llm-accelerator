"""Check four physical DMA lanes and time one real Q4_K Down matrix."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import statistics
import struct
from time import monotonic, perf_counter

import numpy as np
from pynq import Clocks, Overlay, allocate

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('fixture', type=Path)
args = parser.parse_args()
root = args.directory.resolve()
ref = np.load(args.fixture)


def load_overlay(directory, clocks):
    receipt = json.loads((directory / 'accepted.json').read_text())
    if min(receipt['wns_ns'], receipt['whs_ns']) < 0:
        raise ValueError('Timing did not pass')
    for name, digest in receipt['files'].items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f'Hash mismatch: {name}')
    overlay = Overlay(str(directory / 'head_quad_2017.bit'), download=False)
    for lane in range(4):
        addr = overlay.ip_dict[f'dma{lane}']['phys_addr']
        if addr != 0x40400000 + lane * 0x10000:
            raise ValueError(f'Unexpected DMA address for lane {lane}')
    overlay.download()
    actual = (Clocks.fclk0_mhz, Clocks.fclk1_mhz)
    if any(abs(a-b) > 0.05 for a, b in zip(actual, clocks)):
        raise ValueError(f'Unexpected clocks {actual}')
    return overlay, actual


def execute(dmas, sends, receives):
    start = perf_counter()
    for dma, dst in zip(dmas, receives):
        dma.recvchannel.transfer(dst)
    for dma, src in zip(dmas, sends):
        dma.sendchannel.transfer(src)
    deadline = monotonic() + 5
    for dma in dmas:
        channels = (dma.sendchannel, dma.recvchannel)
        while not all(c.idle for c in channels):
            if any(c.error for c in channels) or monotonic() >= deadline:
                raise RuntimeError(f'DMA error or timeout: {dma.register_map}')
        for channel in channels:
            channel.wait()
    return (perf_counter() - start) * 1000


with open('/tmp/blite-perf.lock', 'rb') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    freq = Path('/sys/firmware/devicetree/base/axi/slcr@f8000000/clkc@100/ps-clk-frequency')
    Clocks._instance._ref_clk_mhz = struct.unpack('>I', freq.read_bytes())[0] / 1e6
    try:
        overlay, actual = load_overlay(root, (125, 100))
        dmas = [getattr(overlay, f'dma{i}') for i in range(4)]
        sends = [allocate(shape=src.shape, dtype=src.dtype) for src in ref['send']]
        receives = [allocate(shape=dst.shape, dtype=dst.dtype) for dst in ref['expected']]
        try:
            for buf, src in zip(sends, ref['send']):
                buf[:] = src
            samples = []
            for _ in range(21):
                samples.append(execute(dmas, sends, receives))
                for lane, (dma, dst, expected) in enumerate(zip(dmas, receives, ref['expected'])):
                    if dma.recvchannel.transferred != dst.nbytes:
                        raise ValueError(f'DMA{lane} unexpected S2MM length')
                    if not np.array_equal(dst, expected):
                        raise ValueError(f'DMA{lane} results differ from the integer reference')
            print(json.dumps(dict(clocks_mhz=actual, columns=int(ref['columns']),
                                  tx_bytes=sum(b.nbytes for b in sends),
                                  rx_bytes=sum(b.nbytes for b in receives),
                                  median_ms=statistics.median(samples[1:]), samples_ms=samples)))
            print('Q4-MAC-BOARD-PASS')
        finally:
            for buf in sends + receives:
                buf.freebuffer()
    finally:
        _, original = load_overlay(Path('/home/xilinx/ax7020-decode2017'), (83.333333,))
        print(f'RESIDENT-RESTORED {original[0]}', flush=True)
