"""Generate a 2017.4-compatible copy; never mutate the delivery snapshot."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[2]
source = root / 'accel/rtl'
out = root / 'build/vivado2017/rtl'
out.mkdir(parents=True, exist_ok=True)
text = (source / 'fpu32.v').read_text(encoding='utf8')
# Older XSim mishandles the descending priority loops using a mutable found
# flag. An ascending scan with last-match priority has identical truth tables.
for width, index in [('W', 'hb'), ('56', 'msb')]:
    upper = 'W-1' if width == 'W' else '55'
    old = f"{index} = 0; found = 1'b0;\n        for (i = {upper}; i >= 0; i = i - 1)\n            if (!found && av[i]) begin {index} = i[7:0]; found = 1'b1; end"
    new = f"{index} = 0; found = |av;\n        for (i = 0; i < {width}; i = i + 1)\n            if (av[i]) {index} = i;"
    if text.count(old) != 1:
        raise SystemExit(f'Expected exactly one original {index} priority loop')
    text = text.replace(old, new)
target = out / 'fpu32.v'
if not target.exists() or target.read_text(encoding='utf8') != text:
    target.write_text(text, encoding='utf8')
for name in ['blite_core.v', 'blite_axis_top.v']:
    data = (source / name).read_bytes()
    target = out / name
    if not target.exists() or target.read_bytes() != data:
        target.write_bytes(data)
manifest = {
    'source': {name: hashlib.sha256((source/name).read_bytes()).hexdigest()
               for name in ['fpu32.v', 'blite_core.v', 'blite_axis_top.v']},
    'generated': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.v')},
}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf8')
print(f'Prepared compatibility RTL: {out}')
