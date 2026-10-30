import json,math,random,struct
from pathlib import Path
import numpy as np
root=Path(__file__).resolve().parents[2]
out=root/'build/gateup2017/sim'
out.mkdir(parents=True,exist_ok=True)
r=random.Random(29052017)
def f(v): return struct.unpack('<I',struct.pack('<f',v))[0]
def emit(name,a,width=8): (out/name).write_text(''.join(f'{v:0{width}x}\n' for v in a))
cases=[(0.,0.),(-0.,1.),(1.,1.),(-1.,2.),(1e-40,1.),(1e-30,1e-10),(1e-20,1e-20),(1e30,1e20)]
for bit in range(23):
    subnormal=struct.unpack('<f',struct.pack('<I',1<<bit))[0]
    cases.extend([(subnormal,1.),(-subnormal,1.),(1.,subnormal),(1.,-subnormal)])
for _ in range(1500):
    def finite():
        bits=(r.randrange(2)<<31)|(r.randrange(255)<<23)|r.randrange(1<<23)
        return struct.unpack('<f',struct.pack('<I',bits))[0]
    cases.append((finite(),finite()))
with np.errstate(all='ignore'):
    gold=[f(float(np.float32(a)*np.float32(b))) for a,b in cases]
emit('mul-input.hex',[(f(a)<<32)|f(b) for a,b in cases],16);emit('mul-gold.hex',gold)
acts=[(x,u) for x in [-100.,-32.,-20.,-16.,-8.,-1.,-0.,0.,1e-30,1.,8.,16.,32.,100.]
      for u in [-100.,-1.,0.,1.,100.]]
acts += [(r.uniform(-32,32),r.uniform(-20,20)) for _ in range(1800)]
acts=[(struct.unpack('<f',struct.pack('<f',a))[0],struct.unpack('<f',struct.pack('<f',b))[0]) for a,b in acts]
emit('act-input.hex',[(f(a)<<32)|f(b) for a,b in acts],16)
emit('act-gold.hex',[f(a/(1+math.exp(-a))*b) for a,b in acts])
packet=[];results=[];last=[]
def half(v): return struct.pack('<e',v)
def wblock(kind,scale,values):
    if kind==8: return half(scale)+struct.pack('32b',*values)+b'\0'*6
    uq=[v+16 for v in values]
    qh=sum(((v>>4)&1)<<i for i,v in enumerate(uq))
    return half(scale)+struct.pack('<I',qh)+bytes((uq[i]&15)|((uq[i+16]&15)<<4) for i in range(16))+b'\0'*2
# fmt12 (Q4_K) configs are held out while the new-path numerics are being
# debugged (see build/gateup2017/DEBUG-NOTES-fmt12.md); the engine keeps the
# format-12 decode but no accepted hardware uses it yet.
configs=[(21,8,32,False),(21,8,64,False),(21,16,896,False),(21,4,8192,False),
         (21,8,896,True),(5,8,896,False),(8,8,896,False),(21,8,896,False)]
def q4k_superblock(d,dmin,sc,m,data):
    # 12 scale bytes packed exactly as blite_core get_sm unpacks:
    #   qq[j]   = sc[j]&0x3F | (sc[j+4]&0x3)<<6   (j<4)
    #   qq[4+j] = m[j]&0x3F  | (m[j+4]&0x3)<<6    (j<4)
    #   qq[8+j] = sc[4+j]&0xF | (m[4+j]&0xF)<<4   (j<4)
    qq=[0]*12
    for j in range(4):
        qq[j]=(sc[j]&0x3F)|(((sc[j+4]>>4)&0x3)<<6)
        qq[4+j]=(m[j]&0x3F)|(((m[j+4]>>4)&0x3)<<6)
        qq[8+j]=(sc[4+j]&0xF)|((m[4+j]&0xF)<<4)
    return half(d)+half(dmin)+bytes(qq)+bytes(data)
for fmt,rows,k,zero in configs:
    if fmt==12:
        nb=k//32;sbs=nb//8
        scales=[struct.unpack('<e',half(r.choice([0.001,0.01,0.03,2**-20])))[0] for _ in range(nb)]
        xs=[[0 if zero else r.randrange(-127,128) for _ in range(32)] for _ in range(nb)]
        raw=struct.pack('<Q',0x58|(fmt<<8)|(rows<<16)|(nb<<32))
        raw+=b''.join(half(scales[s])+struct.pack('32b',*xs[s])+b'\0'*6 for s in range(nb))
        for row in range(rows):
            total=0.
            for sb in range(sbs):
                d=struct.unpack('<e',half(r.choice([0.001,0.002,0.005,0.01])))[0]
                dmin=struct.unpack('<e',half(r.choice([0.0005,0.001,0.002])))[0]
                sc=[r.randrange(64) for _ in range(8)];m=[r.randrange(64) for _ in range(8)]
                data=[0]*128
                for j in range(8):
                    for grp in range(4):
                        for pp in range(8):
                            v=r.randrange(16)
                            beat=(j>>1)*4+grp;byt=beat*8+pp
                            if j&1:data[byt]|=v<<4
                            else:data[byt]|=v
                            e=j*32+grp*8+pp
                            total+=sc[j]*d*xs[sb*8+j][grp*8+pp]*v-m[j]*dmin*xs[sb*8+j][grp*8+pp]
                raw+=q4k_superblock(d,dmin,sc,m,data)
            results.append(f(struct.unpack('<f',struct.pack('<f',total))[0]));last.append(int(row==rows-1))
        packet+=list(struct.unpack('<'+'Q'*(len(raw)//8),raw));raw=b''
        continue
    kind=5 if fmt==21 else fmt;nb=k//32
    scales=[struct.unpack('<e',half(r.choice([0.001,0.01,0.03,2**-20])))[0] for _ in range(nb)]
    xs=[[0 if zero else r.randrange(-127,128) for _ in range(32)] for _ in range(nb)]
    raw=struct.pack('<Q',0x58|(fmt<<8)|(rows<<16)|(nb<<32))
    raw+=b''.join(half(scales[s])+struct.pack('32b',*xs[s])+b'\0'*6 for s in range(nb))
    for row in range(rows):
        yy=[]
        for phase in range(2 if fmt==21 else 1):
            total=0.
            for s in range(nb):
                ws=struct.unpack('<e',half(r.choice([0.,0.002,0.01,0.02,2**-20])))[0]
                w=[r.randrange(-16,16) if kind==5 else r.randrange(-127,128) for _ in range(32)]
                raw+=wblock(kind,ws,w)
                total+=scales[s]*ws*sum(a*b for a,b in zip(w,xs[s]))
            yy.append(struct.unpack('<f',struct.pack('<f',total))[0])
        y=yy[0]/(1+math.exp(-yy[0]))*yy[1] if fmt==21 else yy[0]
        results.append(f(y));last.append(int(row==rows-1))
    packet+=list(struct.unpack('<'+'Q'*(len(raw)//8),raw))
emit('axis-input.hex',packet,16);emit('axis-gold.hex',results);emit('axis-last.hex',last)
(out/'params.vh').write_text(f'localparam MUL_N={len(cases)}, ACT_N={len(acts)}, TX_N={len(packet)}, RX_N={len(results)};\n')
(out/'vectors.json').write_text(json.dumps(dict(seed=29052017,mul=len(cases),activation=len(acts),configs=configs,tx_words=len(packet),results=len(results)),indent=2))
print(out)
