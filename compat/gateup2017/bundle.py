import argparse,hashlib,json,sys,tarfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
out=root/'build/gateup2017'
sys.path.insert(0,str(root/'build/upstream/llama.cpp-dafae66cc242eb766797194d3c85c5e502625623/gguf-py'))
from gguf import GGUFReader
p=argparse.ArgumentParser();p.add_argument('--model',required=True);a=p.parse_args()
r=GGUFReader(a.model)
tensors={t.name:t for t in r.tensors}
raw=b''.join(tensors[f'blk.0.ffn_{kind}.weight'].data.tobytes() for kind in ['gate','up'])
(out/'real-gate-up.bin').write_bytes(raw)
with tarfile.open(out/'software.tar.gz','w:gz') as t:
    for p in (out/'software').rglob('*'):
        if p.is_file():t.add(p,arcname=str(Path('software')/p.relative_to(out/'software')))
    for p in (root/'compat/gateup2017/board').glob('*'):
        if p.is_file():t.add(p,arcname='board/'+p.name)
    t.add(root/'compat/gateup2017/build_board.sh',arcname='build_board.sh')
    for name in ['load_overlay.py','test_baseline.sh','test_model.sh','run.sh']:
        t.add(root/'compat/gateup2017'/name,arcname=name)
    t.add(out/'real-gate-up.bin',arcname='vectors/real-gate-up.bin')
(out/'real-gate-up.json').write_text(json.dumps(dict(layer=0,rows=4864,k=896,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()),indent=2))
print(out/'software.tar.gz')
