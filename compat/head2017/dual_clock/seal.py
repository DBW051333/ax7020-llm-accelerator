"""Seal a routed dual-clock bit/HWH pair for the board loader."""
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

build = Path(sys.argv[1])
accept = Path(__file__).resolve().parents[1] / "accept.py"
receipt = json.loads(subprocess.check_output([sys.executable, str(accept), *sys.argv[1:]], text=True))
modules = ET.parse(build / "head_quad_2017.hwh").findall(".//MODULE")
(ps,) = [module for module in modules if module.get("INSTANCE") == "ps7"]
params = {p.get("NAME"): p.get("VALUE") for p in ps.findall("./PARAMETERS/PARAMETER")}
receipt["fclk_mhz"] = [float(params[f"PCW_ACT_FPGA{i}_PERIPHERAL_FREQMHZ"]) for i in range(2)]
print(json.dumps(receipt, indent=2))
