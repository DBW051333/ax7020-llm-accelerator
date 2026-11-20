#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export XILINX_XRT=/usr BLITE_ENABLE=0 BLITE_Q58=0 BLITE_PROFILE=0 BLITE_GATEUP_VERIFY=0 BLITE_GATEUP=1 BLITE_HEAD=1
pynq=/usr/local/share/pynq-venv/bin/python3
decode=/home/xilinx/ax7020-decode2017
v5=/home/xilinx/ax7020-gateup2017
model=$v5/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
ref=${1:?Provide the directory of a validated staged run}
out=$(mktemp -d "$PWD/resident-logs.XXXXXX")
chmod 755 "$out"
echo "RESIDENT_LOG_DIR=$out"
grep CmaTotal /proc/meminfo
test "$(awk '/CmaTotal/ {print $2}' /proc/meminfo)" -ge 360000
"$pynq" "$decode/load_head.py"
common=(-m "$model" -c 256 -b 64 -ub 64 -t 2 -p 'Write a short story about a robot.' --temp 0 -s 1234 --no-warmup --no-display-prompt -n 24)
run() {
    local name=$1 resident=$2 poll=$3
    shift 3
    echo "START $name"
    if ! env BLITE_RESIDENT_GATE="$resident" "$@" timeout 220 ./llama-cli-resident "${common[@]}" --poll "$poll" >"$out/$name.stdout" 2>"$out/$name.stderr"; then
        tail -40 "$out/$name.stderr"; return 1
    fi
    grep -E 'GATEUP-STATS|RESIDENT-GATEUP|HEAD-(RESIDENT|STATS)|prompt eval time|^[^:]+: +eval time' "$out/$name.stderr"
    grep -q 'GATEUP-STATS calls=553 ' "$out/$name.stderr"
    grep -q 'HEAD-STATS calls=24 pl_rows=151936 cpu_rows=0 ' "$out/$name.stderr"
    if [[ $resident == 1 ]]; then grep -q 'RESIDENT-GATEUP calls=553 fallback=0 layers=24 ' "$out/$name.stderr"; fi
}
for ext in tokens logits; do ln -s "$ref/gate-diag.$ext" "$out/gate-diag.$ext"; done
run head-diag 1 50 BLITE_DIAG_PREFIX="$out/head-diag" BLITE_DIAG_FORCE="$ref/force.tokens"
"$pynq" "$decode/compare_decode.py" "$out"
run staged 0 50
run resident-default-a 1 50
run resident-poll0-a 1 0
run resident-poll0-b 1 0
run resident-default-b 1 50
for name in staged resident-default-a resident-default-b resident-poll0-a resident-poll0-b; do
    cmp "$ref/gate-a.stdout" "$out/$name.stdout"
done
echo RESIDENT_BOARD_PASS
