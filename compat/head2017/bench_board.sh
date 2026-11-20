#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export XILINX_XRT=/usr
pynq=/usr/local/share/pynq-venv/bin/python3
baseline=/home/xilinx/ax7020-gateup2017
model=$baseline/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
expected=23c36f3a641c0062f5f60b1b98c652233a40adcc2c9f6c24df87d2e2b996248c
printf '%s  %s\n' "$expected" "$model" | sha256sum -c
gcc -O3 -mcpu=cortex-a9 -mfpu=neon -Wall -Wextra -Werror head_bench.c -o head_bench -ldl -lm -pthread
./head_bench "$model" 5952032 fixture cpu
# Restore the known-good deployment after the isolated test.
restore() {
    status=$?
    trap - EXIT
    if ! "$pynq" "$baseline/load_overlay.py"; then status=1; fi
    exit "$status"
}
trap restore EXIT
"$pynq" load_head.py
for mask in 1 3 5 15; do
    if [ "$mask" = 15 ]; then export HEAD_TRY_FULL_RESIDENT=1; fi
    ./head_bench "$model" 5952032 fixture "$mask"
done
HEAD_HYBRID=1 ./head_bench "$model" 5952032 fixture 15
