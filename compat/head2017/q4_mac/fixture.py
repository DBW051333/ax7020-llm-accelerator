"""Pack Q4_K weights for the AXI test lane and compute its reference sums."""
import argparse
from pathlib import Path
import numpy as np

BLOCKS = 19


def packet(weights, columns):
    # GGML packs 32 low nibbles, then 32 high nibbles in each 32-byte group.
    packed = weights[..., 16:].reshape(-1, 4, 32)
    q = np.stack((packed & 15, packed >> 4), axis=2).reshape(-1, 8, 32)
    scale_bytes = weights[..., 4:16].reshape(-1, 12)
    scales = np.concatenate((scale_bytes[:, :4] & 63,
                             (scale_bytes[:, 8:12] & 15) | ((scale_bytes[:, :4] >> 6) << 4)), axis=1)
    header = np.zeros((len(q), 8), dtype=np.uint8)
    header[:] = scales
    body = np.concatenate((header, (q[..., ::2] | (q[..., 1::2] << 4)).reshape(-1, 128)), axis=1)
    prefix = columns.reshape(len(columns), BLOCKS * 16, 16).transpose(1, 0, 2)
    stream = prefix.tobytes() + body.tobytes()
    activation = np.tile(columns.reshape(len(columns), BLOCKS, 8, 32),
                         (1, len(q) // BLOCKS, 1, 1)).astype(np.int32)
    expected = np.zeros((len(q), 2), dtype='<i4')
    expected[:, :len(columns)] = ((activation * q).sum(axis=3) * scales).sum(axis=2).T
    return stream, expected


def fixture(rows, model=None):
    rng = np.random.default_rng(7020)
    if model:
        from gguf import GGUFReader
        tensor = next(t for t in GGUFReader(model).tensors if t.name == 'blk.3.ffn_down.weight')
        weights = np.asarray(tensor.data[:rows]).reshape(rows, BLOCKS, 144)
    else:
        weights = rng.integers(0, 256, (rows, BLOCKS, 144), dtype=np.uint8)
    columns = rng.integers(-128, 128, (2, BLOCKS * 256), dtype=np.int8)
    columns[0, :256] = -128
    columns[1, :256] = 127
    return weights, columns


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('columns', choices=(1, 2), type=int)
    parser.add_argument('--model')
    parser.add_argument('--board', type=Path)
    args = parser.parse_args()
    if args.board:
        weights, activation = fixture(896, args.model)
        lanes = [packet(data, activation[:args.columns]) for data in np.split(weights, 4)]
        np.savez(args.board, send=np.stack([np.frombuffer(tx, dtype='u1') for tx, _ in lanes]),
                 expected=np.stack([rx for _, rx in lanes]), columns=args.columns)
        return
    weights, activation = fixture(2, args.model)
    stream, expected = packet(weights, activation[:args.columns])
    for path, data in (('stream.hex', stream), ('expected.hex', expected.tobytes())):
        Path(path).write_text(''.join(data[i:i+8][::-1].hex() + '\n' for i in range(0, len(data), 8)))


if __name__ == '__main__':
    main()
