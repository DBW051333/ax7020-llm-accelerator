#!/bin/bash
# Same native binary/model/parameters; verification is separate from timing.
set -euo pipefail
cd "$(dirname "$0")"
export XILINX_XRT=/usr
mkdir -p logs fail-dump
model=models/qwen2.5-0.5b-instruct-q4_k_m.gguf
expected=23c36f3a641c0062f5f60b1b98c652233a40adcc2c9f6c24df87d2e2b996248c
printf '%s  %s\n' "$expected" "$model" | sha256sum -c -
common=(-m "$model" -c 256 -b 64 -ub 64 -t 2 \
        -p 'Write a short story about a robot.' --temp 0 -s 1234 --no-warmup \
        --no-display-prompt)
env BLITE_ENABLE=1 BLITE_VERIFY=1 BLITE_PROFILE=0 BLITE_DUMP_DIR="$PWD/fail-dump" \
  timeout 240 bin/llama-cli-blite "${common[@]}" -n 4 \
  >logs/model-verify.stdout 2>logs/model-verify.stderr
grep 'BLITE-VERIFY\|BLITE-STATS\|eval time' logs/model-verify.stderr
grep -q BLITE-VERIFY logs/model-verify.stderr
grep -Eq 'BLITE-STATS calls=[1-9][0-9]*' logs/model-verify.stderr
for mode in cpu pl cpu-repeat; do
  enable=0
  if [ "$mode" = pl ]; then enable=1; fi
  env BLITE_ENABLE="$enable" BLITE_VERIFY=0 BLITE_PROFILE=0 \
    timeout 300 bin/llama-cli-blite "${common[@]}" -n 24 \
    >"logs/model-$mode.stdout" 2>"logs/model-$mode.stderr"
  grep 'BLITE-STATS\|eval time' "logs/model-$mode.stderr"
done
grep -Eq 'BLITE-STATS calls=[1-9][0-9]*' logs/model-pl.stderr
cmp logs/model-cpu.stdout logs/model-pl.stdout
cmp logs/model-cpu-repeat.stdout logs/model-pl.stdout
sha256sum "$model" bin/llama-cli-blite logs/model-cpu.stdout logs/model-pl.stdout logs/model-cpu-repeat.stdout
echo MODEL-TEST-PASS
