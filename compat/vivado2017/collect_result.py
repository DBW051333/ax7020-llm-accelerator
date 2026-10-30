"""Create an auditable record only after a complete, timing-accepted rebuild."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys
import zipfile

root = Path(__file__).resolve().parents[2]
out = root / 'build/vivado2017/quad-2017'
for audit in ['verification_receipt.py', 'audit_netlist.py', 'audit_handoff.py']:
    args = [sys.executable,str(Path(__file__).parent/audit)]
    if audit == 'verification_receipt.py':
        args.append('--check')
    subprocess.run(args, check=True)
logs = [root/'build/vivado2017/implementation.log',root/'build/vivado2017/all.log',
        root/'build/vivado2017/impl.log',root/'build/vivado2017/export.log']
accepted = [p for p in logs if p.exists() and re.search(r'^REBUILD2017-PASS ',p.read_text(errors='replace'),re.M)]
if not accepted:
    raise SystemExit('No successful timing-accepted implementation log')
log = max(accepted,key=lambda p:p.stat().st_mtime)
match = re.search(r'^REBUILD2017-PASS WNS=([-\d.]+) WHS=([-\d.]+)',log.read_text(errors='replace'),re.M)
if not match or min(map(float,match.groups()))<0:
    raise SystemExit('Invalid setup/hold acceptance record')
files = [out/('blite_quad_2017'+suffix) for suffix in ['.bit','.hwh','.hwdef','.hdf']]
timing = (out/'timing.rpt').read_text()
for required in ['All user specified timing constraints are met.',
                 'There are 0 register/latch pins with no clock.',
                 'There are 0 pins that are not constrained for maximum delay.']:
    if required not in timing:
        raise SystemExit(f'Timing completeness check failed: {required}')
drc = out/'project/blite_quad_2017.runs/impl_1/blite_quad_wrapper_drc_routed.rpt'
if re.search(r'\|\s*(Error|Critical Warning)\s*\|',drc.read_text(),re.I):
    raise SystemExit('DRC contains errors or critical warnings')
with zipfile.ZipFile(out/'blite_quad_2017.hdf') as archive:
    for suffix in ['.bit','.hwh']:
        members = [name for name in archive.namelist() if name.endswith(suffix)]
        if len(members)!=1 or archive.read(members[0]) != (out/('blite_quad_2017'+suffix)).read_bytes():
            raise SystemExit(f'HDF payload differs from exported {suffix}')
    if 'ps7_init.tcl' not in archive.namelist():
        raise SystemExit('HDF missing PS7 initialization')
files += [out/'timing.rpt',out/'utilization.rpt',out/'netlist-audit.json',out/'handoff-audit.json',
          root/'build/vivado2017/rtl/manifest.json',root/'build/vivado2017/verification.json',log,drc]
for p in files:
    if not p.is_file() or p.stat().st_size==0:
        raise SystemExit(f'Missing build artifact: {p}')
record = {'status':'REBUILD2017-PASS','tool':'Vivado 2017.4',
          'part':'xc7z020clg400-2','lanes':4,'requested_fclk_mhz':83.333,
          'setup_slack_ns':float(match.group(1)),'hold_slack_ns':float(match.group(2)),
          'timing_constraints_met':True,'no_unclocked_registers':True,'no_unconstrained_max_delay_pins':True,
          'hdf_payload_matches_exports':True,'drc_errors_or_critical_warnings':False,
          'board_programmed':False,'board_numeric_tested':False,
          'files':{p.relative_to(root).as_posix():{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),
                     'bytes':p.stat().st_size} for p in files}}
(out/'rebuild-result.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf8')
print(f'ACCEPTED: {out / "rebuild-result.json"}')
