"""Verify and load the routed dual-clock overlay."""
import fcntl
import hashlib
import json
import struct
import sys
from pathlib import Path
from pynq import Clocks, Overlay

here = Path(sys.argv[1]).resolve()
receipt = json.loads((here / "accepted.json").read_text())
if min(receipt["wns_ns"], receipt["whs_ns"]) < 0:
    raise ValueError("Timing was not accepted")
for name in ("head_quad_2017.bit", "head_quad_2017.hwh"):
    if hashlib.sha256((here / name).read_bytes()).hexdigest() != receipt["files"][name]:
        raise ValueError(f"Artifact hash mismatch: {name}")
with open("/tmp/blite-perf.lock", "rb") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    freq = Path("/sys/firmware/devicetree/base/axi/slcr@f8000000/clkc@100/ps-clk-frequency")
    Clocks._instance._ref_clk_mhz = struct.unpack(">I", freq.read_bytes())[0] / 1e6
    overlay = Overlay(str(here / "head_quad_2017.bit"), download=False)
    for lane in range(4):
        if overlay.ip_dict[f"dma{lane}"]["phys_addr"] != 0x40400000 + lane * 0x10000:
            raise ValueError(f"Unexpected DMA{lane} address")
    overlay.download()
    actual = [Clocks.fclk0_mhz, Clocks.fclk1_mhz]
    if any(abs(a-b) > 0.05 for a, b in zip(actual, receipt.get("fclk_mhz", [83.333333]))):
        raise RuntimeError(f"FCLK readback {actual} != {receipt['fclk_mhz']}")
    print("DUAL-CLOCK-LOADED", actual, receipt, flush=True)
