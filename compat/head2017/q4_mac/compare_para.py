"""Report fixed-history projection comparisons with explicit result gates."""
import argparse
import json
from pathlib import Path
import struct

import numpy as np


def read_logits(path):
    with path.open("rb") as f:
        while header := f.read(4):
            (n,) = struct.unpack("<I", header)
            if n != 151936:
                raise ValueError("Unexpected vocabulary size")
            row = np.frombuffer(f.read(4*n), dtype="<f4")
            if len(row) != n or not np.isfinite(row).all():
                raise ValueError("Incomplete or nonfinite logits")
            yield row


def compare(out, left, right):
    ref, candidate = (np.loadtxt(out / (tag + ".tokens"), dtype=int) for tag in (left, right))
    if ref.shape != candidate.shape or ref.ndim != 2 or not np.array_equal(ref[:, 1], candidate[:, 1]):
        raise ValueError("Different fixed token history")
    first = None
    total = mismatches = 0
    maximum = 0.0
    equal_bits = True
    a = read_logits(out / (left + ".logits"))
    b = read_logits(out / (right + ".logits"))
    for i, (x, y) in enumerate(zip(a, b, strict=True)):
        total += 1
        maximum = max(maximum, np.max(np.abs(x-y)).item())
        equal_bits &= x.tobytes() == y.tobytes()
        p, q = int(x.argmax()), int(y.argmax())
        if p != q:
            mismatches += 1
            if first is None:
                first = dict(step=i+1, reference=p, candidate=q,
                             reference_gap=float(x[p]-x[q]), candidate_gap=float(y[p]-y[q]))
    if total != len(ref):
        raise ValueError("Unexpected number of comparison steps")
    print(json.dumps(dict(steps=total, max_abs=maximum, bitwise_equal=equal_bits,
                          top1_mismatches=mismatches, first=first), ensure_ascii=False))
    return equal_bits


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("results", type=Path)
    p.add_argument("reference")
    p.add_argument("candidate")
    p.add_argument("--exact", action="store_true")
    args = p.parse_args()
    exact = compare(args.results, args.reference, args.candidate)
    raise SystemExit(int(args.exact and not exact))
