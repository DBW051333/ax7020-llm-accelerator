#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if pgrep -x llama-cli-a9 || pgrep -x llama-cli-resid || pgrep -x llama-cli-para; then exit 1; fi
pynq=/usr/local/share/pynq-venv/bin/python3
sudo env XILINX_XRT=/usr "$pynq" load_para.py overlay
exec sudo env XILINX_XRT=/usr BLITE_GATEUP=1 BLITE_HEAD=1 BLITE_RESIDENT_GATE=1 \
    BLITE_ENABLE=0 BLITE_Q58=0 BLITE_PARA_MAC=1 ./llama-cli-para \
    -m /home/xilinx/ax7020-gateup2017/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
    -cnv -if -c 1024 -b 64 -ub 64 -t 2 --poll 50 --temp 0 -s 1234 --no-warmup -n 8192 \
    -p 'You are a helpful assistant.' "$@"
