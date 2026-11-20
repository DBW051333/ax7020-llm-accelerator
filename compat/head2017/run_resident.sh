#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
cma=$(awk '/CmaTotal/ {print $2}' /proc/meminfo)
if (( cma < 360000 )); then
    echo 'Resident mode needs the tested 384 MiB CMA boot profile.' >&2
    exit 1
fi
decode=/home/xilinx/ax7020-decode2017
model=/home/xilinx/ax7020-gateup2017/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 "$decode/load_head.py"
exec sudo env XILINX_XRT=/usr BLITE_GATEUP=1 BLITE_HEAD=1 BLITE_RESIDENT_GATE=1 BLITE_GATEUP_VERIFY=0 BLITE_ENABLE=0 BLITE_Q58=0 \
    ./llama-cli-resident -m "$model" -cnv -if -c 512 -b 64 -ub 64 -t 2 --poll "${RESIDENT_POLL:-50}" \
    --temp 0 -s 1234 --no-warmup -n 8192 -p 'You are a helpful assistant.' "$@"
