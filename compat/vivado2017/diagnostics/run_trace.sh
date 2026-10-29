#!/bin/bash
# Serial runs, same prompt and CPU-forced history. Original validation logs untouched.
set -euo pipefail
cd /home/xilinx/ax7020-validation2017
export XILINX_XRT=/usr BLITE_VERIFY=0 BLITE_PROFILE=0
mkdir -p diagnosis2017/logs
common=(-m models/qwen2.5-0.5b-instruct-q4_k_m.gguf -c 256 -b 64 -ub 64 -t 2
        -p 'Write a short story about a robot.' --temp 0 -s 1234 --no-warmup
        --no-display-prompt -n 24)
for mode in cpu pl-forced pl-reference cpu-repeat; do
    prefix="$PWD/diagnosis2017/logs/$mode"
    test ! -e "$prefix.logits"
    enable=0
    extra=()
    if [ "$mode" != cpu ] && [ "$mode" != cpu-repeat ]; then
        enable=1
        extra+=(BLITE_DIAG_FORCE="$PWD/diagnosis2017/logs/cpu-force.tokens")
    fi
    if [ "$mode" = pl-reference ]; then
        extra+=(BLITE_DIAG_USE_REF=1)
        echo 'CAUSAL EXPERIMENT: hardware runs, CPU reference replaces each Q4 output; not acceptance/performance'
    fi
    env BLITE_ENABLE="$enable" BLITE_DIAG_PREFIX="$prefix" BLITE_DIAG_TRACE="$prefix.matvec" \
        "${extra[@]}" timeout 360 bin/llama-cli-diagnostic "${common[@]}" \
        >"$prefix.stdout" 2>"$prefix.stderr"
    if [ "$mode" = cpu ]; then
        awk '{print $2}' "$prefix.tokens" >diagnosis2017/logs/cpu-force.tokens
        cmp "$prefix.stdout" logs/model-cpu.stdout
    fi
    grep 'BLITE-STATS\|eval time' "$prefix.stderr"
    echo "TRACE-DONE $mode"
done
cmp diagnosis2017/logs/cpu.stdout diagnosis2017/logs/cpu-repeat.stdout
cmp diagnosis2017/logs/cpu.logits diagnosis2017/logs/cpu-repeat.logits
echo CPU-REPEAT-LOGITS-IDENTICAL
sha256sum bin/llama-cli-diagnostic models/qwen2.5-0.5b-instruct-q4_k_m.gguf
