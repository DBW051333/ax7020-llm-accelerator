#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
release=/home/xilinx/ax7020-decode2017
resident=/home/xilinx/ax7020-resident2017
model=/home/xilinx/ax7020-gateup2017/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
pynq=/usr/local/share/pynq-venv/bin/python3
flock -n /tmp/blite-perf.lock true
if pgrep -x llama-cli-resid || pgrep -x llama-cli-a9; then
    echo "Interactive model already running"
    exit 1
fi
export XILINX_XRT=/usr
if [[ -n ${A9_OVERLAY_LOADER:-} ]]; then
    restore() {
        local rc=$?
        trap - EXIT
        "$pynq" "$release/load_head.py" || exit 1
        exit "$rc"
    }
    trap restore EXIT
fi
"$pynq" "${A9_OVERLAY_LOADER:-$release/load_head.py}"
out=$(mktemp -d "$PWD/results.XXXXXX")
chmod 755 "$out"
echo "RESULTS=$out"
common=(-m "$model" -c "${A9_CONTEXT:-256}" -t 2 -b 64 -ub 64 --poll 50 --temp 0 -s 1234
    --no-warmup --no-display-prompt -n 24 -p 'Write a short story about a robot.')
export BLITE_ENABLE=0 BLITE_Q58=0 BLITE_HEAD=1 BLITE_GATEUP=1
export BLITE_RESIDENT_GATE=1 BLITE_PROFILE=0 BLITE_GATEUP_VERIFY=0
run() {
    local name=$1 bin=$2
    shift 2
    echo "START $name"
    if ! env "$@" timeout 180 "$bin" "${common[@]}" >"$out/$name.out" 2>"$out/$name.log"; then
        tail -40 "$out/$name.log"
        return 1
    fi
    grep -E 'eval time|RESIDENT-GATEUP calls|HEAD-STATS' "$out/$name.log"
    grep -q 'RESIDENT-GATEUP calls=553 fallback=0 layers=24 ' "$out/$name.log"
    grep -q 'HEAD-STATS calls=24 pl_rows=151936 cpu_rows=0 ' "$out/$name.log"
}
run gate-diag "$resident/llama-cli-resident" BLITE_DIAG_PREFIX="$out/gate-diag"
awk '{print $2}' "$out/gate-diag.tokens" >"$out/force.tokens"
run head-diag "$PWD/llama-cli-a9" BLITE_DIAG_PREFIX="$out/head-diag" BLITE_DIAG_FORCE="$out/force.tokens"
"$pynq" compare_decode.py "$out"
cmp "$out/gate-diag.logits" "$out/head-diag.logits"
run baseline-a "$resident/llama-cli-resident"
run candidate-a "$PWD/llama-cli-a9"
run candidate-b "$PWD/llama-cli-a9"
run baseline-b "$resident/llama-cli-resident"
for name in candidate-a candidate-b baseline-b; do cmp "$out/baseline-a.out" "$out/$name.out"; done
echo A9_BOARD_PASS
