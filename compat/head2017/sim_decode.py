"""Alternate Head/GateUp packets through one combined RTL lane."""
from pathlib import Path
import subprocess
import sys

src = Path(__file__).resolve().parent
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable,str(src/'sim_vectors.py'),str(out)],check=True)
words=(out/'input.hex').read_text().splitlines()
expected=(out/'output.hex').read_text().splitlines()
# Two-row Q5_0 GateUp request with zero activation and weight blocks.
# Both outputs are zero, independent of the scale and SiLU realization.
gate=['0000000100021558']+['0000000000000000']*(5+2*6)
gold=['00000000000000000','10000000000000000']
split=120+19*119
(out/'input.hex').write_text('\n'.join(gate+words[:split]+gate+words[split:]+gate)+'\n')
(out/'output.hex').write_text('\n'.join(gold+expected[:19]+gold+expected[19:]+gold)+'\n')
tb=(src/'tb.sv').read_text().replace('INPUT_WORDS=4048, OUTPUT_WORDS=32','INPUT_WORDS=4102, OUTPUT_WORDS=38')
tb=tb.replace('head_lane dut(clk,rst_n,data,valid,last,ready,result,out_valid,out_last,out_ready,);',
              'decode_lane dut(clk,rst_n,data,valid,last,ready,result,out_valid,out_last,out_ready,);')
assert 'decode_lane dut' in tb
(out/'tb.sv').write_text(tb)
