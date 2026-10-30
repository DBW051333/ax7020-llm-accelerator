"""Independent integer reference for the truncating normalization converters."""
from pathlib import Path
import random

def fp32(value, fractional_bits=0):
    if not value:
        return 0
    magnitude = abs(value)
    highest = magnitude.bit_length() - 1
    return ((value < 0) << 31) | ((highest-fractional_bits+127) << 23) | (((magnitude << 23) >> highest) & 0x7fffff)

rng = random.Random(201704)
values = [0, -(1 << 55), (1 << 55)-1]
for bit in range(55):
    for delta in [-1, 0, 1]:
        values.extend([(1 << bit)+delta, -((1 << bit)+delta)])
values += [rng.randrange(-(1 << 55), 1 << 55) for _ in range(1000)]
lines = [f'{len(values):048x}']
for index, value in enumerate(values):
    integer = [0, -(1 << 23), (1 << 23)-1][index] if index < 3 else rng.randrange(-(1 << 23), 1 << 23)
    scale = index % 64
    packed = (((value & ((1 << 56)-1)) << 30) | ((integer & 0xffffff) << 6) | scale) << 96
    packed |= fp32(value,18) << 64 | fp32(integer) << 32 | fp32(scale)
    lines.append(f'{packed:048x}')
out = Path(__file__).resolve().parents[2] / 'build/vivado2017/sim/normalization'
out.mkdir(parents=True, exist_ok=True)
(out / 'normalization.hex').write_text('\n'.join(lines)+'\n',encoding='ascii')
print(f'Generated {len(values)} independent normalization vectors')
