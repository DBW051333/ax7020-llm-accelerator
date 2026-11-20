"""Create a loader receipt for one implemented and timing-accepted prototype."""
from pathlib import Path
import hashlib
import json
import re
import sys

build = Path(sys.argv[1])
console = Path(sys.argv[2]).read_text(encoding='utf-8', errors='replace')
markers = re.findall(r'^REBUILD2017-PASS WNS=([-0-9.]+) WHS=([-0-9.]+)', console, re.M)
if len(markers) != 1:
    raise SystemExit('expected one implementation acceptance marker')
wns, whs = map(float, markers[0])
if min(wns, whs) < 0:
    raise SystemExit('negative slack')
drc = (build/'drc.rpt').read_text()
if re.search(r'\|\s*(?:Critical Warning|Error)\s*\|', drc):
    raise SystemExit('check the DRC report before loading')
files = {}
for extension in ('bit', 'hwh'):
    path = build/f'head_quad_2017.{extension}'
    files[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
print(json.dumps(dict(wns_ns=wns, whs_ns=whs, files=files), indent=2))
