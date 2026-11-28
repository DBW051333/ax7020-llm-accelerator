#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec 8> .para-dsp.lock
flock -n 8
if pgrep -x llama-cli-para || pgrep -x llama-cli-a9 || pgrep -x llama-cli-resid; then exit 19; fi
flock -n 9 9</tmp/blite-perf.lock
root=/home/xilinx/ax7020-para-mac
pynq=/usr/local/share/pynq-venv/bin/python3
model=/home/xilinx/ax7020-gateup2017/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
export XILINX_XRT=/usr BLITE_GATEUP=1 BLITE_HEAD=1 BLITE_RESIDENT_GATE=1
export BLITE_GATEUP_VERIFY=0 BLITE_ENABLE=0 BLITE_Q58=0 BLITE_PROFILE=0 BLITE_PARA_MAC=1
out=$(mktemp -d "$PWD/results.XXXXXX")
chmod 755 "$out"
echo "RESULTS=$out"
clock_overlay() { "$pynq" "$root/load_para.py" "$1"; }
trap 'clock_overlay /home/xilinx/ax7020-decode2017' EXIT
args=(-m "$model" -c 1024 -b 64 -ub 64 -t 2 --poll 50 --temp 0 -s 1234
      --no-warmup --no-display-prompt -p 'Write a short story about a robot.')
run() {
    local id=$1 overlay=$2 tokens=$3
    shift 3
    clock_overlay "$overlay"
    echo "RUN $id"
    env "$@" timeout 160 "$root/llama-cli-para" "${args[@]}" -n "$tokens" >"$out/$id.out" 2>"$out/$id.log"
    grep -E '^PARA-MAC|^HEAD-STATS|^RESIDENT-GATEUP|^llama_perf_context_print: +eval time' "$out/$id.log"
    grep -Eq '^PARA-MAC calls=[1-9][0-9]* fallback=0 groups=12 ' "$out/$id.log"
    grep -Eq '^HEAD-STATS .* pl_rows=151936 cpu_rows=0 ' "$out/$id.log"
    grep -Eq '^RESIDENT-GATEUP .* fallback=0 layers=24 ' "$out/$id.log"
}
original=${PARA_LUT_OVERLAY:-$root/overlay}
run reference "$original" 24 BLITE_DIAG_PREFIX="$out/reference"
awk '{print $2}' "$out/reference.tokens" > "$out/force.tokens"
for width in "$@"; do
    run "check$width" "dsp$width" 24 BLITE_DIAG_PREFIX="$out/check$width" \
        BLITE_DIAG_FORCE="$out/force.tokens" BLITE_PARA_VERIFY=1
    grep -Eq '^PARA-MAC .* values=[1-9][0-9]* differences=0$' "$out/check$width.log"
    "$pynq" "$root/compare_para.py" "$out" reference "check$width" --exact
done
export BLITE_PARA_TIMING=1
run original0 "$original" 48
for width in "$@"; do run "dsp${width}a" "dsp$width" 48; done
widths=("$@")
for ((i=${#widths[@]}-1;i>=0;i--)); do run "dsp${widths[i]}b" "dsp${widths[i]}" 48; done
run original1 "$original" 48
for f in "$out"/dsp*.out "$out"/original1.out; do cmp "$out/original0.out" "$f"; done
echo PARA_DSP_BOARD_PASS
