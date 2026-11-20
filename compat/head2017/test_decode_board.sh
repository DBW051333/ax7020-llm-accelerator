#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export XILINX_XRT=/usr BLITE_ENABLE=0 BLITE_Q58=0 BLITE_PROFILE=0 BLITE_GATEUP_VERIFY=0
pynq=/usr/local/share/pynq-venv/bin/python3
v5=/home/xilinx/ax7020-gateup2017
model=$v5/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
out=$(mktemp -d "$PWD/decode-logs.XXXXXX")
chmod 755 "$out"
echo "DECODE_LOG_DIR=$out"
printf '%s  %s\n' 23c36f3a641c0062f5f60b1b98c652233a40adcc2c9f6c24df87d2e2b996248c "$model" | sha256sum -c
restore_on_failure() {
    status=$?
    trap - EXIT
    if (( status != 0 )); then "$pynq" "$v5/load_overlay.py"; fi
    exit "$status"
}
trap restore_on_failure EXIT
"$pynq" load_head.py | tee "$out/overlay.log"
BLITE_GATEUP=1 BLITE_HEAD=0 bin/test_gateup "$v5/vectors/real-gate-up.bin" 2>&1 | tee "$out/dma.log"
grep -q 'REAL-GATEUP-PASS' "$out/dma.log"
common=(-m "$model" -c 256 -b 64 -ub 64 -t 2 -p 'Write a short story about a robot.' --temp 0 -s 1234 --no-warmup --no-display-prompt -n 24)
run() {
    local name=$1 head=$2
    shift 2
    echo "START $name"
    if ! env BLITE_GATEUP=1 BLITE_HEAD="$head" "$@" timeout 200 bin/llama-cli-decode "${common[@]}" >"$out/$name.stdout" 2>"$out/$name.stderr"; then
        tail -32 "$out/$name.stderr"; return 1
    fi
    grep -E 'GATEUP-STATS|HEAD-(RESIDENT|STATS)|prompt eval time|^[^:]+: +eval time' "$out/$name.stderr"
    grep -q 'GATEUP-STATS calls=553 ' "$out/$name.stderr"
    if [[ $head == 1 ]]; then grep -q 'HEAD-STATS calls=24 ' "$out/$name.stderr"; fi
}
run gate-diag 0 BLITE_DIAG_PREFIX="$out/gate-diag"
awk '{print $2}' "$out/gate-diag.tokens" >"$out/force.tokens"
run head-diag 1 BLITE_DIAG_PREFIX="$out/head-diag" BLITE_DIAG_FORCE="$out/force.tokens"
"$pynq" compare_decode.py "$out" | tee "$out/comparison.log"
run gate-a 0
run head-a 1
run head-b 1
run gate-b 0
cmp "$out/gate-a.stdout" "$out/gate-b.stdout"
cmp "$out/head-a.stdout" "$out/head-b.stdout"
if cmp -s "$out/gate-a.stdout" "$out/head-a.stdout"; then echo HEAD_TEXT_MATCH; else echo HEAD_TEXT_DIFFERS; fi
echo DECODE_BOARD_PASS
