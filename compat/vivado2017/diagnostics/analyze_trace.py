"""Compare raw logits and Q4 traces under an identical CPU token history."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import numpy as np

parser=argparse.ArgumentParser()
parser.add_argument('--dir',type=Path,default=Path('build/logits-diagnosis2017/logs'))
parser.add_argument('--model',type=Path,required=True)
args=parser.parse_args()
d=args.dir

def logits(path):
    a=[]
    with path.open('rb') as f:
        while h:=f.read(4):
            n,=struct.unpack('<I',h)
            v=np.frombuffer(f.read(n*4),dtype='<f4').copy()
            assert len(v)==n and np.isfinite(v).all()
            a.append(v)
    return np.stack(a)

def traces(path):
    a=[]
    with path.open('rb') as f:
        while h:=f.read(16):
            nl,k,n,q=struct.unpack('<IIII',h)
            name=f.read(nl).decode()
            x=np.frombuffer(f.read(k*4),dtype='<f4').copy()
            q8=f.read(q)
            y=np.frombuffer(f.read(n*4),dtype='<f4').copy()
            ref=np.frombuffer(f.read(n*4),dtype='<f4').copy()
            assert len(ref)==n and np.isfinite(x).all() and np.isfinite(y).all()
            a.append(dict(name=name,x=x,q=q8,y=y,ref=ref))
    return a

def error(a,b):
    delta=a.astype('float64')-b.astype('float64')
    norm=np.linalg.norm(b.astype('float64'))
    return dict(max_abs=float(np.max(np.abs(delta))),relative_l2=float(np.linalg.norm(delta)/(norm or 1)),
                different_values=int(np.count_nonzero(a!=b)))

# Decode token pieces directly from the exact local GGUF metadata, not another tokenizer.
root=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(root/'build/upstream/llama.cpp-dafae66cc242eb766797194d3c85c5e502625623/gguf-py'))
from gguf import GGUFReader
reader=GGUFReader(str(args.model))
field=reader.fields['tokenizer.ggml.tokens']
def piece(i):
    return bytes(field.parts[field.data[int(i)]]).decode('utf8')

all_logits={m:logits(d/(m+'.logits')) for m in ['cpu','pl-forced','pl-reference','cpu-repeat']}
tokens={m:np.loadtxt(d/(m+'.tokens'),dtype=int).reshape(-1,2) for m in all_logits}
cpu=all_logits['cpu']; pl=all_logits['pl-forced']; ref=all_logits['pl-reference']
assert all(a.shape==cpu.shape for a in all_logits.values())
assert np.array_equal(cpu,all_logits['cpu-repeat'])
assert np.array_equal(tokens['cpu'][:,1],tokens['pl-forced'][:,1])
assert np.array_equal(tokens['cpu'][:,1],tokens['pl-reference'][:,1])
for mode,v in all_logits.items():
    assert np.array_equal(np.argmax(v,axis=1),tokens[mode][:,0]), 'raw argmax differs from greedy sampler: '+mode
steps=[]
for s,(c,p) in enumerate(zip(cpu,pl)):
    ci=int(np.argmax(c)); pi=int(np.argmax(p)); best=np.argsort(c)[-5:][::-1]
    top_union=list(dict.fromkeys([*map(int,best),*map(int,np.argsort(p)[-5:][::-1])]))
    def probability(v,i):
        v=v.astype('float64')-float(np.max(v))
        return float(np.exp(v[i])/np.exp(v).sum())
    steps.append(dict(step=s,cpu_choice=ci,pl_choice=pi,cpu_piece=piece(ci),pl_piece=piece(pi),
        sampled_cpu=int(tokens['cpu'][s,0]),sampled_pl=int(tokens['pl-forced'][s,0]),
        cpu_top1_minus_top2=float(c[best[0]]-c[best[1]]),
        cpu_pair_margin=float(c[ci]-c[pi]),pl_pair_margin=float(p[ci]-p[pi]),
        error=error(p,c),candidates=[dict(id=i,piece=piece(i),cpu_logit=float(c[i]),pl_logit=float(p[i]),
            delta=float(p[i]-c[i]),cpu_probability=probability(c,i),pl_probability=probability(p,i)) for i in top_union]))
first=next((s for s in steps if s['sampled_cpu']!=s['sampled_pl']),None)
ct=traces(d/'cpu.matvec'); pt=traces(d/'pl-forced.matvec')
assert len(ct)==len(pt)
assert len(ct)==12*(len(steps)-1), 'unexpected eligible layer/decode count'
layer=[]
for idx,(c,p) in enumerate(zip(ct,pt)):
    assert c['name']==p['name']
    qdiff=sum(a!=b for a,b in zip(c['q'],p['q']))
    cq=np.frombuffer(c['q'],dtype=np.uint8).reshape(-1,292)
    pq=np.frombuffer(p['q'],dtype=np.uint8).reshape(-1,292)
    layer.append(dict(index=idx,decode_step=idx//12+1,name=c['name'],
        input_error=error(p['x'],c['x']),q8_different_bytes=qdiff,
        q8_quantized_value_differences=int(np.count_nonzero(cq[:,4:260]!=pq[:,4:260])),
        output_error=error(p['y'],c['y']),pl_same_input_reference_error=error(p['y'],p['ref']),
        cpu_same_input_reference_error=error(c['y'],c['ref'])))
result=dict(status='DIAGNOSTIC-ONLY',steps=len(steps),vocab_size=cpu.shape[1],
    cpu_repeat_logits_bitwise_equal=True,forced_token_sequences_equal=True,
    first_sample_divergence=first,logits_steps=steps,
    reference_substitution=dict(description='Hardware executes; each Q4 output explicitly replaced with CPU vec_dot on its own quantized input.',
        logits_bitwise_equal=bool(np.array_equal(ref,cpu)),error=error(ref,cpu),
        sampled_tokens_equal=bool(np.array_equal(tokens['pl-reference'][:,0],tokens['cpu'][:,0]))),
    q4_trace_records=len(layer),first_output_difference=next((l for l in layer if l['output_error']['different_values']),None),
    first_q8_integer_difference=next((l for l in layer if l['q8_quantized_value_differences']),None),
    max_local_pl_reference_relative_l2=max(l['pl_same_input_reference_error']['relative_l2'] for l in layer),
    layers=layer,
    file_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(d.iterdir()) if p.is_file()})
(d.parent/'analysis.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({k:v for k,v in result.items() if k not in ['logits_steps','layers','file_sha256']},ensure_ascii=False,indent=2))
