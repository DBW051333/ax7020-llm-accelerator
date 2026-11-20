"""Build independent block-matvec goldens for two AXIS requests."""
from pathlib import Path
import random
import struct
import sys

out = Path(sys.argv[1])
rng = random.Random(42)
in_words, out_words = [], []

def make_row(seed):
    values = []
    for j in range(28):
        scale = [-0.03125, 0.0, 0.0234375, 2**-24, 0.8798828125][(seed+j)%5]
        qs = [rng.randrange(-128, 128) for _ in range(32)]
        values.append((scale, qs))
    return values

def encode(row):
    return b''.join(struct.pack('<e32b', scale, *values) for scale, values in row)

for rows in (19, 13):
    activation = make_row(rows)
    weights = [make_row(i) for i in range(rows)]
    packet = struct.pack('<II', 0x38444851, rows) + encode(activation)
    packet += b''.join(map(encode, weights))
    in_words.extend(f'{x[0]:016x}\n' for x in struct.iter_unpack('<Q', packet))
    for index, weight in enumerate(weights):
        expected = sum(dw * dx * sum(w*x for w, x in zip(qw, qx))
                       for (dw, qw), (dx, qx) in zip(weight, activation))
        bits, = struct.unpack('<I', struct.pack('<f', expected))
        out_words.append(f'{int(index == rows-1):x}{bits:016x}\n')
(out/'input.hex').write_text(''.join(in_words), encoding='ascii')
(out/'output.hex').write_text(''.join(out_words), encoding='ascii')
