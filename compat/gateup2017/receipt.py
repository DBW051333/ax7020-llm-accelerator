import argparse,hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parents[2]
b=root/'build/gateup2017'
p=argparse.ArgumentParser();p.add_argument('--check',action='store_true');a=p.parse_args()
paths=list((b/'rtl').glob('*'))+list((b/'sim').glob('*.hex'))+[root/'compat/gateup2017/tb.sv',b/'sim/simulation.txt']
hashes={str(p.relative_to(root)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()}
receipt=b/'verified.json'
if a.check:
    assert json.loads(receipt.read_text())==hashes,'RTL/test/vectors changed since verification'
else:
    raw=(b/'sim/simulation.txt').read_bytes()
    log=raw.decode('utf-16') if raw.startswith(b'\xff\xfe') else raw.decode('utf8')
    assert all(m in log for m in ['FP-MUL-PASS','SILU-MUL-PASS','GATEUP-AXIS-PASS'])
    assert 'Fatal:' not in log
    receipt.write_text(json.dumps(hashes,indent=2))
print('GATEUP-RECEIPT-PASS')
