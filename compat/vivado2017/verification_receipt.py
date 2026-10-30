"""Bind successful XSim logs to the exact RTL, testbench and vector files."""
from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[2]
receipt = root / 'build/vivado2017/verification.json'
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

if '--check' in sys.argv:
    data = json.loads(receipt.read_text(encoding='utf8'))
    for relative, digest in data['files'].items():
        path = root / relative
        if not path.is_file() or sha(path) != digest:
            raise SystemExit(f'Verification is stale or missing: {relative}')
    print('VERIFICATION-RECEIPT-PASS')
else:
    tests = {'normalization': 'NORMALIZATION-PASS 1333 vectors',
             'core': 'TB-PASS: 8 rows, 0 errors', 'axis': 'AXIS-TB-PASS',
             'real-stall': 'REAL-STALL-PASS'}
    files = list((root/'build/vivado2017/rtl').glob('*.v'))
    files += list((root/'accel/rtl').glob('*.hex'))
    files += [root/'accel/rtl/tb_core.v', root/'accel/rtl/tb_axis.v']
    files += [p for p in (root/'accel/verify/real-stall').iterdir() if p.is_file()]
    files += list((root/'compat/vivado2017').glob('*.sv'))
    files += [root/'compat/vivado2017/prepare_rtl.py', root/'compat/vivado2017/normalization_vectors.py']
    for name, marker in tests.items():
        directory = root / 'build/vivado2017/sim' / name
        log = directory / 'simulation.txt'
        raw = log.read_bytes()
        text = raw.decode('utf16' if raw.startswith(b'\xff\xfe') else 'utf-8-sig')
        if marker not in text or any(failure in text for failure in ['TB-FAIL', 'TIMEOUT', 'Fatal:', 'NORMALIZATION-FAIL']):
            raise SystemExit(f'Simulation not accepted: {name}')
        files.extend([log, directory/'compile.txt', directory/'elaborate.txt', directory/'run.tcl'])
        files.extend(directory.glob('*.hex'))
    receipt.write_text(json.dumps({'tool': 'Vivado XSim 2017.4', 'tests': tests,
        'files': {p.relative_to(root).as_posix():sha(p) for p in files}}, indent=2)+'\n', encoding='utf8')
    print(f'Verification receipt: {receipt}')
