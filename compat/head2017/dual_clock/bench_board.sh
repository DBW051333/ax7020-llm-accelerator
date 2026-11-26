#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
home=/home/xilinx
pynq=/usr/local/share/pynq-venv/bin/python3
baseline=$home/ax7020-decode2017/load_head.py
resident=$home/ax7020-resident2017
v5=$home/ax7020-gateup2017
model=$v5/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
flock -n /tmp/blite-perf.lock true
if pgrep -x llama-cli-resid; then
    echo "Interactive model active"; exit 1
fi
[[ $(awk '/CmaTotal/ { print $2 }' /proc/meminfo) -ge 360000 ]]
out=$(mktemp -d "$here/results.XXXXXX")
chmod 755 "$out"
echo "RESULTS=$out"
export XILINX_XRT=/usr BLITE_ENABLE=0 BLITE_Q58=0 BLITE_HEAD=1 BLITE_GATEUP=1
export BLITE_RESIDENT_GATE=1 BLITE_PROFILE=0 BLITE_GATEUP_VERIFY=0
common=(-m "$model" -c 256 -t 2 -b 64 -ub 64 --poll 50 --temp 0 -s 1234
        --no-warmup --no-display-prompt -n 24 -p 'Write a short story about a robot.')
run() {
    local log=$1
    shift
    env "$@" timeout 180 "$resident/llama-cli-resident" "${common[@]}" >"$out/$log.stdout" 2>"$out/$log.stderr"
    grep -q 'RESIDENT-GATEUP calls=553 fallback=0 layers=24 ' "$out/$log.stderr"
    grep -q 'HEAD-STATS calls=24 pl_rows=151936 cpu_rows=0 ' "$out/$log.stderr"
    grep -E 'eval time|HEAD-STATS|RESIDENT-GATEUP' "$out/$log.stderr"
}
bench() {
    local name=$1
    BLITE_HEAD=0 timeout 75 "$resident/test_gateup_resident" "$v5/vectors/real-gate-up.bin" 2>&1 | tee "$out/$name-dma.log"
    grep -q 'REAL-GATEUP-PASS' "$out/$name-dma.log"
    run "$name-a"
    run "$name-b"
    cmp "$out/$name-a.stdout" "$out/$name-b.stdout"
}
restore() {
    local rc=$?
    trap - EXIT
    "$pynq" "$baseline" || exit 1
    exit "$rc"
}
"$pynq" "$baseline"
bench baseline
if [[ ${1:-} == --baseline ]]; then exit; fi
run gate-diag BLITE_DIAG_PREFIX="$out/gate-diag"
awk '{print $2}' "$out/gate-diag.tokens" >"$out/force.tokens"
trap restore EXIT
"$pynq" "$here/load.py"
bench candidate
cmp "$out/baseline-a.stdout" "$out/candidate-a.stdout"
run head-diag BLITE_DIAG_PREFIX="$out/head-diag" BLITE_DIAG_FORCE="$out/force.tokens"
"$pynq" "$here/compare_decode.py" "$out" | tee "$out/comparison.log"
echo DUAL_CLOCK_BOARD_PASS
