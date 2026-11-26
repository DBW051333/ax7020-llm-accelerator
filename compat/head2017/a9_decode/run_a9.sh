#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if pgrep -x llama-cli-resid || pgrep -x llama-cli-a9; then
    echo 'A model session is already active.'
    exit 1
fi
cma=$(awk '/CmaTotal/ {print $2}' /proc/meminfo)
if (( cma < 360000 )); then
    echo 'Resident mode needs the tested 384 MiB CMA boot profile.' >&2
    exit 1
fi
loader=${A9_OVERLAY_LOADER:-/home/xilinx/ax7020-dual-clock-100/load.py}
model=/home/xilinx/ax7020-gateup2017/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 "$loader"
exec sudo env XILINX_XRT=/usr BLITE_GATEUP=1 BLITE_HEAD=1 BLITE_RESIDENT_GATE=1 BLITE_GATEUP_VERIFY=0 BLITE_ENABLE=0 BLITE_Q58=0 \
    ./llama-cli-a9 -m "$model" -cnv -if -c 1024 -b 64 -ub 64 -t 2 --poll "${RESIDENT_POLL:-50}" \
    --temp 0 -s 1234 --no-warmup -n 8192 -p 'You are a helpful assistant.' "$@"
