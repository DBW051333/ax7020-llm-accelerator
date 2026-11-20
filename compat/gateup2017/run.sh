#!/bin/bash
# Explicitly load the matching experimental overlay before manual chat.
set -euo pipefail
cd /home/xilinx/ax7020-gateup2017
sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 load_overlay.py
# Qwen2.5 has add_bos_token=false: with -cnv -if and no -p the token list is
# empty and llama-cli aborts with "input is empty" — provide a default system
# prompt (a later -p in "$@" overrides it).
exec sudo env XILINX_XRT=/usr BLITE_GATEUP=1 BLITE_GATEUP_VERIFY=0 BLITE_ENABLE=0 BLITE_Q58=0 \
 bin/llama-cli-gateup -m models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
 -cnv -if -c 512 -b 64 -ub 64 -t 2 --temp 0 -s 1234 --no-warmup -n 64 \
 -p "You are a helpful assistant." "$@"
