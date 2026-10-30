#!/bin/bash
# Native Cortex-A9 build of the pinned, patched llama.cpp source snapshot.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin logs
gcc -O2 -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
  -o bin/perf_parallel board/perf_parallel.c -ldl -lm
cmake -S llama.cpp -B llama-build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_PROCESSOR=armv7-a \
  -DCMAKE_C_FLAGS='-mcpu=cortex-a9 -mfp16-format=ieee -mfpu=neon-vfpv3 -mfloat-abi=hard' \
  -DCMAKE_CXX_FLAGS='-mcpu=cortex-a9 -mfp16-format=ieee -mfpu=neon-vfpv3 -mfloat-abi=hard' \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_BLITE=ON \
  -DGGML_BLITE_DIR="$PWD/board" -DGGML_OPENMP=OFF -DGGML_LLAMAFILE=OFF \
  -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF
cmake --build llama-build --target llama-cli -j 2
cp llama-build/bin/llama-cli bin/llama-cli-blite
sha256sum bin/perf_parallel bin/llama-cli-blite
echo BOARD-BUILD-PASS
