import argparse,hashlib,json,os,re,subprocess,sys,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--tag',default='quad-2017-v2');p.add_argument('--log',default='build-v2.log');a=p.parse_args()
b=root/'build/gateup2017';out=b/a.tag
os.environ['GATEUP_BUILD_TAG']=a.tag
subprocess.run([sys.executable,str(Path(__file__).with_name('receipt.py')),'--check'],check=True)
subprocess.run([sys.executable,str(Path(__file__).with_name('audit.py'))],check=True)
s=(b/a.log).read_text(errors='replace')
m=re.search(r'^REBUILD2017-PASS WNS=([-\d.]+) WHS=([-\d.]+)',s,re.M)
assert m and min(map(float,m.groups()))>=0,'No accepted export'
timing=(out/'timing.rpt').read_text()
for expected in ['All user specified timing constraints are met.',
                 'There are 0 register/latch pins with no clock.',
                 'There are 0 pins that are not constrained for maximum delay.']:
    assert expected in timing,expected
drc=out/'project/gateup_quad_2017.runs/impl_1/gateup_quad_wrapper_drc_routed.rpt'
assert not re.search(r'\|\s*(Error|Critical Warning)\s*\|',drc.read_text(),re.I)
files=[out/('gateup_quad_2017'+ext) for ext in ['.bit','.hwh','.hwdef','.hdf']]
with zipfile.ZipFile(out/'gateup_quad_2017.hdf') as z:
    for ext in ['.bit','.hwh']:
        names=[n for n in z.namelist() if n.endswith(ext)]
        assert len(names)==1 and z.read(names[0])==(out/('gateup_quad_2017'+ext)).read_bytes()
    assert 'ps7_init.tcl' in z.namelist()
for f in files:assert f.is_file() and f.stat().st_size>0
accepted=dict(status='GATEUP-HARDWARE-ACCEPTED',wns_ns=float(m[1]),whs_ns=float(m[2]),frequency_mhz=83.333333,
    files={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files if f.suffix in ['.bit','.hwh']})
(out/'accepted.json').write_text(json.dumps(accepted,indent=2))
print(json.dumps(accepted,indent=2))
