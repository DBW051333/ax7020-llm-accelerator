#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
resident=/home/xilinx/ax7020-resident2017
release=/home/xilinx/ax7020-decode2017
root=$release/llama.cpp/ggml
lib=$release/llama-build/ggml/src
cc -O3 -I"$root/include" -I"$root/src" -I"$root/src/ggml-cpu" -c bench_k.c -o bench_k.o
for mode in baseline candidate; do
    archive=$resident/libggml-cpu.a
    if [[ $mode == candidate ]]; then archive=libggml-cpu.a; fi
    c++ bench_k.o -o "bench-$mode" -Wl,--start-group "$lib/libggml.a" "$archive" "$lib/libggml-base.a" -Wl,--end-group -ldl -lpthread -lm
done
for mode in baseline candidate candidate baseline; do
    echo "BENCH_K $mode"
    "./bench-$mode" "$mode.f32"
done
cmp baseline.f32 candidate.f32
echo K_QUANTS_BITWISE_PASS
