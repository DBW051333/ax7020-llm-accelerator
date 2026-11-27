#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
pynq=/usr/local/share/pynq-venv/bin/python3
model=/home/xilinx/ax7020-gateup2017/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
if pgrep -x llama-cli-a9 || pgrep -x llama-cli-resid || pgrep -x llama-cli-para || pgrep -x llama-cli-proje; then exit 1; fi
flock -n 9 9</tmp/blite-perf.lock
export XILINX_XRT=/usr BLITE_GATEUP=1 BLITE_HEAD=1 BLITE_RESIDENT_GATE=1
export BLITE_GATEUP_VERIFY=0 BLITE_ENABLE=0 BLITE_Q58=0 BLITE_PROFILE=0
out=$(mktemp -d "$PWD/results.para.XXXXXX")
chmod 755 "$out"
echo "RESULTS=$out"
loader=load_para.py
restore() {
    local status=$?
    trap - EXIT
    "$pynq" "$loader" /home/xilinx/ax7020-decode2017 || exit 1
    exit "$status"
}
trap restore EXIT
"$pynq" "$loader" overlay
common=(-m "$model" -c 1024 -b 64 -ub 64 -t 2 --poll 50 --temp 0 -s 1234
        --no-warmup --no-display-prompt -p 'Write a short story about a robot.')
run() {
    local tag=$1 mac=$2 tokens=$3
    shift 3
    echo "RUN $tag para=$mac tokens=$tokens"
    env BLITE_PARA_MAC="$mac" "$@" timeout 240 ./llama-cli-para "${common[@]}" -n "$tokens" >"$out/$tag.out" 2>"$out/$tag.log" || {
        tail -45 "$out/$tag.log"; return 1
    }
    grep -E 'PARA-|HEAD-STATS|RESIDENT-GATEUP|^[^:]+: +eval time' "$out/$tag.log"
    grep -Eq 'HEAD-STATS .* pl_rows=151936 cpu_rows=0 ' "$out/$tag.log"
    grep -Eq 'RESIDENT-GATEUP .* fallback=0 layers=24 ' "$out/$tag.log"
    if (( mac )); then grep -Eq 'PARA-MAC calls=[1-9][0-9]* fallback=0 groups=12 ' "$out/$tag.log"; fi
}
run baseline 0 24 BLITE_DIAG_PREFIX="$out/baseline"
awk '{print $2}' "$out/baseline.tokens" > "$out/force.tokens"
run diagnostic 1 24 BLITE_DIAG_PREFIX="$out/diagnostic" BLITE_DIAG_FORCE="$out/force.tokens" BLITE_PARA_VERIFY=1
grep -Eq '^PARA-MAC .* values=[1-9][0-9]* differences=0$' "$out/diagnostic.log"
"$pynq" compare_para.py "$out" baseline diagnostic --exact
steps=${PARA_BENCH_TOKENS:-64}
export BLITE_PARA_TIMING=1
run a0 0 "$steps"
run b0 1 "$steps"
run b1 1 "$steps"
run a1 0 "$steps"
for tag in b0 b1 a1; do cmp "$out/a0.out" "$out/$tag.out"; done
echo PARA_MAC_BOARD_PASS
