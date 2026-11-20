"""Recover quantized Head inputs from captured CPU logits without a rebuild.

The fixture is accepted only if its quantized reconstruction predicts all
151936 logits within the stated tolerance, including held-out rows.
"""
from pathlib import Path
import argparse
import struct
import numpy as np
from gguf import GGUFReader, GGMLQuantizationType

parser = argparse.ArgumentParser()
parser.add_argument('model', type=Path)
parser.add_argument('logits', type=Path)
parser.add_argument('out', type=Path)
args = parser.parse_args()
weights = next(t for t in GGUFReader(str(args.model)).tensors if t.name == 'token_embd.weight')
assert weights.tensor_type == GGMLQuantizationType.Q8_0
assert weights.data.shape == (151936, 952)
with args.logits.open('rb') as f:
    columns = []
    for _ in range(3):
        n, = struct.unpack('<I', f.read(4))
        assert n == len(weights.data)
        columns.append(np.frombuffer(f.read(n*4), dtype='<f4'))
logits = np.column_stack(columns)

def dequantize(rows):
    blocks = rows.reshape(-1, 28, 34)
    scales = np.ascontiguousarray(blocks[:, :, :2]).view('<f2').astype('f8')
    return (blocks[:, :, 2:].view('i1') * scales).reshape(-1, 896)

indices = np.random.default_rng(72).choice(len(logits), 4096, replace=False)
xs = np.linalg.lstsq(dequantize(weights.data[indices]), logits[indices], rcond=None)[0].T
args.out.mkdir(parents=True, exist_ok=True)
print('gguf_weight_offset', weights.data_offset)
for i, vector in enumerate(xs):
    blocks = vector.reshape(28, 32)
    scales = np.asarray(np.max(np.abs(blocks), axis=1)/127, dtype='<f2')[:, None]
    assert np.all(scales > 0)
    qs = np.clip(np.rint(blocks / scales.astype('f8')), -127, 127).astype('i1')
    reconstructed = (qs * scales.astype('f8')).ravel()
    assert np.max(np.abs(reconstructed-vector)) < 1e-4
    reference = np.concatenate([
        dequantize(weights.data[j:j+2048]) @ reconstructed
        for j in range(0, len(logits), 2048)
    ])
    err = np.max(np.abs(reference-logits[:, i]))
    assert err < 5e-5, err
    assert reference.argmax() == logits[:, i].argmax()
    np.concatenate((scales.view('u1'),qs.view('u1')),axis=1).tofile(args.out/f'activation{i}.q8')
    logits[:, i].tofile(args.out/f'expected{i}.f32')
    print('fixture',i,'all_vocab_max_abs',err,'token',reference.argmax())
