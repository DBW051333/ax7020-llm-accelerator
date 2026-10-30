#!/bin/bash
set -euo pipefail
cd /home/xilinx/ax7020-gateup2017
export XILINX_XRT=/usr
mkdir -p logs
common=(-m models/qwen2.5-0.5b-instruct-q4_k_m.gguf -c 256 -b 64 -ub 64 -t 2
        -p 'Write a short story about a robot.' --temp 0 -s 1234 --no-warmup --no-display-prompt -n 24)
test ! -e logs/cpu.logits
env BLITE_ENABLE=0 BLITE_Q58=0 BLITE_GATEUP=0 BLITE_DIAG_PREFIX="$PWD/logs/cpu" \
 timeout 300 bin/llama-cli-gateup "${common[@]}" >logs/cpu.stdout 2>logs/cpu.stderr
cmp logs/cpu.stdout /home/xilinx/ax7020-validation2017/logs/model-cpu.stdout
awk '{print $2}' logs/cpu.tokens >logs/cpu-force.tokens
grep 'eval time' logs/cpu.stderr
env BLITE_ENABLE=1 BLITE_VERIFY=0 BLITE_PROFILE=0 \
 timeout 300 /home/xilinx/ax7020-validation2017/bin/llama-cli-blite "${common[@]}" \
 >logs/q4-baseline.stdout 2>logs/q4-baseline.stderr
grep 'BLITE-STATS\|eval time' logs/q4-baseline.stderr
echo GATEUP-BASELINE-RECORDED
