#!/bin/bash
# Full-length local numeric check; does not waive CPU/PL text-parity failure.
set -euo pipefail
cd "$(dirname "$0")"
export XILINX_XRT=/usr
mkdir -p logs fail-dump
env BLITE_ENABLE=1 BLITE_VERIFY=1 BLITE_PROFILE=0 BLITE_DUMP_DIR="$PWD/fail-dump" \
  timeout 240 bin/llama-cli-blite \
  -m models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  -c 256 -b 64 -ub 64 -t 2 -n 24 \
  -p 'Write a short story about a robot.' --temp 0 -s 1234 \
  --no-warmup --no-display-prompt \
  >logs/model-verify24.stdout 2>logs/model-verify24.stderr
grep -E 'BLITE-VERIFY|BLITE-STATS|eval time' logs/model-verify24.stderr
grep -Eq 'BLITE-STATS calls=[1-9][0-9]*' logs/model-verify24.stderr
cmp logs/model-pl.stdout logs/model-verify24.stdout
echo PL-REPEAT-IDENTICAL
echo VERIFY24-NUMERIC-PASS
