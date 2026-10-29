"""Replay the first captured Q4 matvec using integer arithmetic matching RTL rules.

This checks arithmetic semantics only, not DMA timing or the RTL state machine.
Weights are read from the exact model; no weights are written to the report.
"""
import argparse
import json
import math
from pathlib import Path
import struct
import sys
import numpy as np

p=argparse.ArgumentParser()
p.add_argument('--model',required=True)
p.add_argument('--dir',type=Path,default=Path('build/logits-diagnosis2017'))
a=p.parse_args()
root=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(root/'build/upstream/llama.cpp-dafae66cc242eb766797194d3c85c5e502625623/gguf-py'))
from gguf import GGUFReader
with (a.dir/'logs/pl-forced.matvec').open('rb') as f:
    nl,k,rows,nq=struct.unpack('<IIII',f.read(16))
    name=f.read(nl).decode()
    f.read(k*4)
    q8=f.read(nq)
    actual=np.frombuffer(f.read(rows*4),dtype='<f4').copy()
    reference=np.frombuffer(f.read(rows*4),dtype='<f4').copy()
reader=GGUFReader(a.model)
w=next(t for t in reader.tensors if t.name==name).data.tobytes()
nsb=k//256
assert len(w)==rows*nsb*144

def bits(v): return struct.unpack('<I',struct.pack('<f',v))[0]
def value(v): return struct.unpack('<f',struct.pack('<I',v))[0]
def half(v): return struct.unpack('<e',v)[0]
def mul(x,y):
    ex=(x>>23)&255; ey=(y>>23)&255
    if not ex or not ey: return 0
    assert ex<255 and ey<255
    prod=((x&0x7fffff)|0x800000)*((y&0x7fffff)|0x800000)
    high=prod>>47
    exponent=ex+ey-127+high
    assert 0<exponent<255
    frac=(prod>>(24 if high else 23))&0x7fffff
    return ((x^y)&0x80000000)|(exponent<<23)|frac
def q18(v):
    e=(v>>23)&255
    if not e: return 0
    exponent=e-127
    assert exponent<13, 'saturation outside this replay contract'
    m=(v&0x7fffff)|0x800000
    mag=m<<(exponent-5) if exponent>=5 else m>>(5-exponent)
    return -mag if v>>31 else mag
def acc_float(v):
    if not v: return 0.0
    mag=abs(v); msb=mag.bit_length()-1
    assert mag<2**55
    mant=(mag<<23)>>msb
    return value((int(v<0)<<31)|((msb-18+127)<<23)|(mant&0x7fffff))

max_scale=0.0
for offset in range(0,len(w),144):
    bound=float(np.float32(63.0*np.float32(max(abs(half(w[offset:offset+2])),abs(half(w[offset+2:offset+4]))))*1024))
    max_scale=max(max_scale,bound)
max_d=max(abs(struct.unpack_from('<f',q8,s*292)[0]) for s in range(nsb))
bound=float(np.float32(max_d)*np.float32(max_scale))
shift=max(-60,min(60,12-math.frexp(bound)[1])) if bound else 0
expected=[]
for r in range(rows):
    acc=0
    for s in range(nsb):
        b=w[(r*nsb+s)*144:(r*nsb+s+1)*144]
        dh=bits(math.ldexp(half(b[:2]),10)); mh=bits(math.ldexp(half(b[2:4]),10))
        dx=bits(math.ldexp(struct.unpack_from('<f',q8,s*292)[0],shift))
        scales=b[4:16]
        x=np.frombuffer(q8[s*292+4:s*292+260],dtype=np.int8).astype(np.int64)
        for g in range(8):
            if g<4:
                sc=scales[g]&63; mn=scales[g+4]&63
            else:
                sc=(scales[g+4]&15)|((scales[g-4]>>6)<<4)
                mn=(scales[g+4]>>4)|((scales[g]>>6)<<4)
            raw=np.frombuffer(b[16+(g//2)*32:16+(g//2+1)*32],dtype=np.uint8)
            nib=((raw>>(4*(g%2)))&15).astype(np.int64)
            q=x[g*32:(g+1)*32]
            c1=q18(mul(mul(dh,bits(sc)),dx))
            c2=q18(mul(mul(mh,bits(mn)),dx))
            acc+=c1*int(np.dot(nib,q))-c2*int(q.sum())
    expected.append(math.ldexp(acc_float(acc),-shift-10))
expected=np.array(expected,dtype='<f4')
delta=expected.astype('float64')-reference.astype('float64')
result=dict(layer=name,rows=rows,k=k,activation_shift=shift,weight_shift=10,
    rtl_arithmetic_bitwise_matches_hardware=bool(np.array_equal(expected.view('uint32'),actual.view('uint32'))),
    mismatched_rows=int(np.count_nonzero(expected.view('uint32')!=actual.view('uint32'))),
    max_abs_vs_cpu_reference=float(np.max(np.abs(delta))),
    relative_l2_vs_cpu_reference=float(np.linalg.norm(delta)/np.linalg.norm(reference.astype('float64'))),
    scope='First captured Q4 matvec only. Integer model of truncating FP multipliers, Q18 coefficients, integer MAC and truncating final FP conversion; not a timing/state-machine simulation.')
(a.dir/'rtl-arithmetic.json').write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result,indent=2))
assert result['rtl_arithmetic_bitwise_matches_hardware']
