"""Collect evidence without treating local tolerance as model quality acceptance."""
import argparse,hashlib,json,re,struct
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser();p.add_argument('--dir',type=Path,default=Path('build/gateup2017/board-evidence/logs'));a=p.parse_args()
d=a.dir
def log(mode):return (d/(mode+'.stderr')).read_text(errors='replace')
def logits(mode):
    rows=[]
    with (d/(mode+'.logits')).open('rb') as f:
        while h:=f.read(4):
            n,=struct.unpack('<I',h);v=np.frombuffer(f.read(n*4),dtype='<f4').copy()
            assert len(v)==n and np.isfinite(v).all();rows.append(v)
    return np.stack(rows)
def metric(mode):
    s=log(mode)
    ms,runs=re.search(r'(?<!prompt )eval time\s*=\s*([\d.]+) ms\s*/\s*(\d+) runs',s).groups()
    out=dict(decode_ms=float(ms),decode_runs=int(runs),tokens_per_second=int(runs)*1000/float(ms))
    stats=re.search(r'(?:GATEUP|BLITE)-STATS (.*)',s)
    if stats:out['hardware_stats']=dict(re.findall(r'(\w+)=([\d.]+)',stats[1]))
    return out
c=logits('cpu');cr=logits('cpu-repeat');forced=logits('forced-verify')
assert np.array_equal(c,cr),'CPU logits not repeatable'
ct=np.loadtxt(d/'cpu.tokens',dtype=int).reshape(-1,2)
ft=np.loadtxt(d/'forced-verify.tokens',dtype=int).reshape(-1,2)
assert np.array_equal(ct[:,1],ft[:,1])
assert all(np.array_equal(np.argmax(logits(m),axis=1),np.loadtxt(d/(m+'.tokens'),dtype=int).reshape(-1,2)[:,0])
           for m in ['cpu','forced-verify','cpu-repeat'])
delta=forced.astype('float64')-c.astype('float64')
steps=[]
for i,(cpu,pl) in enumerate(zip(c,forced)):
    ci=int(np.argmax(cpu));pi=int(np.argmax(pl));top=list(dict.fromkeys([ci,pi,*map(int,np.argsort(cpu)[-3:][::-1])]))
    steps.append(dict(step=i,cpu_choice=ci,pl_choice=pi,max_abs=float(np.max(np.abs(delta[i]))),
        relative_l2=float(np.linalg.norm(delta[i])/np.linalg.norm(cpu.astype('float64'))),
        candidates=[dict(token=j,cpu_logit=float(cpu[j]),pl_logit=float(pl[j])) for j in top]))
verify=[float(v) for v in re.findall(r'GATEUP-VERIFY .* relative_L2=([\deE+.-]+)',log('forced-verify'))]
assert len(verify)==553 and max(verify)<=1e-4
assert (d/'fused.stdout').read_bytes()==(d/'fused-repeat.stdout').read_bytes()
modes={m:metric(m) for m in ['cpu-perf','q4-baseline','fused','fused-repeat']}
for m in ['fused','fused-repeat','forced-verify']:
    assert re.search(r'GATEUP-STATS calls=553 ',log(m)),m
result=dict(status='EXPERIMENTAL-BOARD-RESULT',quality_preserving_speedup_accepted=False,
    cpu_repeat_logits_bitwise_equal=True,fused_text_repeatable=True,
    cpu_pl_text_equal=(d/'cpu.stdout').read_bytes()==(d/'fused.stdout').read_bytes(),
    forced_tokens_equal=True,local_verified_calls=len(verify),max_local_relative_l2=max(verify),
    first_forced_choice_divergence=next((s for s in steps if s['cpu_choice']!=s['pl_choice']),None),
    fixed_history_logits_max_abs=float(np.max(np.abs(delta))),steps=steps,performance=modes,
    fused_decode_rate_ratio_vs_cpu=modes['fused']['tokens_per_second']/modes['cpu-perf']['tokens_per_second'],
    fused_decode_rate_ratio_vs_q4=modes['fused']['tokens_per_second']/modes['q4-baseline']['tokens_per_second'],
    file_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in d.iterdir() if p.is_file()})
(d.parent/'board-result.json').write_text(json.dumps(result,indent=2))
print(json.dumps({k:v for k,v in result.items() if k not in ['steps','file_sha256']},indent=2))
