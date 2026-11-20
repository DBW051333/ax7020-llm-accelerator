"""Compare paired Head backends on identical Gate/Up token histories."""
from pathlib import Path
import json
import struct
import sys

import numpy as np


def logits(path):
    with path.open('rb') as stream:
        while header := stream.read(4):
            (vocab,) = struct.unpack('<I', header)
            assert vocab == 151936
            row = np.frombuffer(stream.read(4*vocab), dtype='<f4')
            assert len(row) == vocab and np.isfinite(row).all()
            yield row


root = Path(sys.argv[1])
left, right = (np.loadtxt(root/f'{mode}.tokens', dtype=int) for mode in ('gate-diag', 'head-diag'))
assert left.shape == right.shape == (24, 2)
assert np.array_equal(left[:, 1], right[:, 1])
assert np.array_equal(left[:, 0], right[:, 0])
max_abs = 0
diff2 = ref2 = 0
steps = 0
for baseline, measured in zip(logits(root/'gate-diag.logits'), logits(root/'head-diag.logits'), strict=True):
    steps += 1
    assert baseline.argmax() == measured.argmax()
    delta = baseline.astype('f8') - measured
    max_abs = max(max_abs, float(np.max(np.abs(delta))))
    diff2 += float(delta @ delta)
    ref = baseline.astype('f8')
    ref2 += float(ref @ ref)
relative_l2 = (diff2/ref2)**0.5
print(json.dumps(dict(steps=steps, vocab=151936, max_abs=max_abs, relative_l2=relative_l2,
                      all_sampled_tokens_match=True)))
assert steps == 24 and max_abs <= 5e-5 and relative_l2 <= 1e-5
print('DECODE_LOGITS_PASS')
