"""Summarize whole-decode and later-token wall times from the ABBA runs."""
import argparse
import json
from pathlib import Path
import re
import statistics


def samples(path):
    log = path.read_text()
    match = re.search(r'^.*?:\s+eval time\s+=\s*([0-9.]+) ms /\s*(\d+) runs', log, re.M)
    if not match:
        raise ValueError(f'Missing decode summary in {path}')
    ms, count = float(match[1]), int(match[2])
    steps = [int(us) / 1000 for us in re.findall(r'^PARA-STEP past=\d+ us=(\d+)$', log, re.M)]
    if len(steps) != count or count < 5:
        raise ValueError(f'Unexpected number of wall-clock samples in {path}')
    return dict(eval_ms=ms, count=count, first_ms=steps[0], warm_ms=sum(steps[4:]),
                warm_count=count-4, median_warm_ms=statistics.median(steps[4:]))


def pooled(rows):
    return dict(tps=1000*sum(r['count'] for r in rows)/sum(r['eval_ms'] for r in rows),
                warm_tps=1000*sum(r['warm_count'] for r in rows)/sum(r['warm_ms'] for r in rows))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('results', type=Path)
    args = parser.parse_args()
    runs = {tag:samples(args.results / f'{tag}.log') for tag in ('a0','b0','b1','a1')}
    print(json.dumps(dict(runs=runs, cpu=pooled([runs['a0'],runs['a1']]),
                          para_mac=pooled([runs['b0'],runs['b1']])), indent=2))
