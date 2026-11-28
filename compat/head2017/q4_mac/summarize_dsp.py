"""Summarize decode and later-token timing for the LUT/DSP comparison."""
import json
from pathlib import Path
import sys

from summarize_para import pooled, samples

directory = Path(sys.argv[1])
variants = [('lut64', 'original0', 'original1')]
variants.extend((f'dsp{w}', f'dsp{w}a', f'dsp{w}b') for w in sys.argv[2:])
summary = {}
for name, first, last in variants:
    rows = [samples(directory / f'{tag}.log') for tag in (first, last)]
    summary[name] = dict(**pooled(rows), runs=rows)
print(json.dumps(summary, indent=2))
