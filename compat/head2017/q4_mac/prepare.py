"""Create a four-DMA laboratory overlay with the Q4_K test lane."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

here = Path(__file__).resolve().parent
repo = here.parents[2]

parser = argparse.ArgumentParser()
parser.add_argument("columns", choices=(1, 2), type=int)
args = parser.parse_args()
out = repo / f"build/head2017/q4-mac-{args.columns}"
if out.exists():
    parser.error(f"Use a fresh build directory; exists: {out}")

subprocess.run([sys.executable, str(here.parent / "dual_clock/prepare.py"),
                "--axi", "125", "--compute", "100", "--scale-pipeline",
                "--output", str(out)], check=True)
rtl = out / "rtl"
(rtl / "decode_lane.v").unlink()
source = (here / "decode_lane.sv").read_text()
(rtl / "decode_lane.v").write_text(
    source.replace("parameter COLUMNS = 2", f"parameter COLUMNS = {args.columns}"))
print(out)
