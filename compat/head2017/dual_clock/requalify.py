"""Recheck the same routed fabric at a strictly lower PS compute clock."""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

CLOCK_FIELDS = {
    "PCW_ACT_FPGA1_PERIPHERAL_FREQMHZ",
    "PCW_CLK1_FREQ",
    "PCW_FCLK1_PERIPHERAL_DIVISOR0",
    "PCW_FCLK1_PERIPHERAL_DIVISOR1",
    "PCW_FPGA1_PERIPHERAL_FREQMHZ",
}

def handoff(build):
    return build / "quad/project/head_quad_2017.srcs/sources_1/bd/head_quad/hw_handoff/head_quad.hwh"

def inspect(path):
    tree = ET.parse(path)
    ps = tree.find(".//MODULE[@INSTANCE='ps7']")
    if ps is None:
        raise ValueError(f"Missing PS7 in {path}")
    values = {p.get("NAME"): p.get("VALUE") for p in ps.findall("./PARAMETERS/PARAMETER")}
    hz = values["PCW_CLK1_FREQ"]
    for port in tree.findall(".//PORT[@SIGNAME='ps7_FCLK_CLK1']"):
        if port.get("CLKFREQUENCY") != hz:
            raise ValueError(f"Unexpected FCLK1 port rate in {path}")
        del port.attrib["CLKFREQUENCY"]
    for bus in tree.findall(".//BUSINTERFACE"):
        domain = bus.find("./PARAMETER[@NAME='CLK_DOMAIN']")
        if domain is not None and domain.get("VALUE") == "head_quad_ps7_0_FCLK_CLK1":
            clock = bus.find("./PARAMETER[@NAME='FREQ_HZ']")
            if clock is None or clock.get("VALUE") != hz:
                raise ValueError(f"Unexpected FCLK1 interface rate in {path}")
            clock.set("VALUE", "")
    tree.getroot().attrib.pop("TIMESTAMP", None)
    for p in ps.findall("./PARAMETERS/PARAMETER"):
        if p.get("NAME") in CLOCK_FIELDS:
            p.set("VALUE", "")
    return ET.tostring(tree.getroot()), float(hz)

def verify_skew(path):
    summary = path.read_text().split("2. Bus Skew Details")[0]
    numbers = re.findall(r"^\s*(?:Slow|Fast)\s+[0-9.]+\s+[0-9.]+\s+(-?[0-9.]+)\s*$", summary, re.M)
    if len(numbers) != 16 or min(map(float, numbers)) < 0:
        raise ValueError("Check all 16 FIFO pointer bus-skew constraints")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("routed", type=Path)
    parser.add_argument("lower", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--vivado", default="D:/Xilinx/Vivado/2017.4/bin/vivado.bat")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    original_hwh = handoff(args.routed.resolve())
    lower_hwh = handoff(args.lower.resolve())
    original, high_hz = inspect(original_hwh)
    lower, low_hz = inspect(lower_hwh)
    if original != lower or not 0 < low_hz < high_hz:
        raise ValueError("Lower handoff must match the routed design outside the FCLK1 divider")
    def rtl(directory):
        return {p.name: p.read_bytes() for p in (directory / "rtl").iterdir() if p.is_file()}

    if rtl(args.routed) != rtl(args.lower):
        raise ValueError("The lower and routed builds must use identical RTL and ROM sources")
    out = args.output.resolve()
    out.mkdir(parents=True)
    run = args.routed.resolve() / "quad/project/head_quad_2017.runs/impl_1"
    dcp = run / "head_quad_wrapper_routed.dcp"
    bit = run / "head_quad_wrapper.bit"
    log_path = out / "requalify.log"
    with log_path.open("wb") as log:
        subprocess.run(
            [args.vivado, "-mode", "batch", "-source", str(here / "requalify.tcl"), "-tclargs",
             str(dcp), str(bit), str(lower_hwh), str(out), f"{1e9 / low_hz:.6f}"],
            cwd=out, stdout=log, stderr=subprocess.STDOUT, check=True,
        )
    verify_skew(out / "bus_skew.rpt")
    receipt = subprocess.check_output([sys.executable, str(here / "seal.py"), str(out), str(log_path)])
    (out / "accepted.json").write_bytes(receipt)
    print(receipt.decode().strip())

if __name__ == "__main__":
    main()
