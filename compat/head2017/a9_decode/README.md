# Single-user decode on Cortex-A9

This variant extends Resident while keeping the trained weights and Q8
activation format. The ARMv7 NEON kernels accumulate safe narrow integer
products before widening. Q6_K centers its weights before multiplication.
Q5_0 expands its packed high bit with NEON and keeps the original
lane-level FP32 accumulation order. Q4_K keeps the pinned GCC/ARMv7
binary's block-level FP32 evaluation order.

The rebuild verifies the existing quantization source hash, rebuilds one
object, and relinks using a separate copy of the Resident static archive.
The original binary, model and overlay files are independent of the
candidate.

## Installation and verification

Copy the files in this directory and parent `compare_decode.py` into a
separate directory on the board. Run `python3 build_board.py` against
the established Resident checkout and toolchain. Run `bash bench_k.sh`
to compare full matrix outputs byte for byte, then `sudo bash bench_board.sh`
for fixed-history logits and paired decode throughput.

Set `A9_CONTEXT=1024` and `A9_OVERLAY_LOADER` to an accepted
dual-clock loader to repeat the matching dual-clock run. The benchmark
requires both trials to use all 24 resident Gate/Up layers and a full PL
Head. It restores the original overlay after alternate-overlay tests.

`bash run_a9.sh` opens the interactive model with a 1024-token context
and the existing generation budget. The launcher accepts the same
overrides as the Resident CLI.

## AX7020 board results

Single request, Qwen2.5-0.5B Q4_K_M, two threads, greedy sampling, batch
64, poll 50 and 384 MiB CMA. Normal measurement order was baseline,
candidate, candidate, baseline. Each side has 46 timed decode steps.
The diagnostic runs were measured separately.

| Overlay / context | Baseline decode ms | Candidate decode ms | Pooled token/s | Gain |
| --- | ---: | ---: | --- | ---: |
| Resident 83.33 MHz / 256 | 20070.67 + 19667.01 | 18239.82 + 18171.48 | 1.158 to 1.263 | 9.1% |
| Dual-clock 125/100 MHz / 1024 | 20176.96 + 19157.99 | 18093.27 + 17412.17 | 1.169 to 1.296 | 10.8% |

In the 1024-context test the mean time dropped from 855.1 to 771.9 ms
per generated token. All 24 diagnostic steps matched the original
151,936 logits bit for bit in both configurations. Free output was
identical on the test prompt. All reported timed runs kept 24 Gate/Up
layers resident and all Head rows in PL. An earlier original-overlay run
at context 1024 staged five Gate/Up layers and was excluded before the A/B.

In the separate single-thread matrix microbenchmark, mean time per
896-row matrix changed from 14.33 to 12.29 ms for Q4_K, 19.85 to 16.85 ms
for Q6_K, and 6.94 to 4.98 ms for Q5_0. The outputs matched byte for byte.

The deployed launcher is `~/ax7020-a9-decode/run_a9.sh`. It loads the
accepted 125/100 MHz overlay and defaults to context 1024. Set
`A9_OVERLAY_LOADER=/home/xilinx/ax7020-decode2017/load_head.py` to use
the original clock profile. The launcher was checked through its help
entry point and the benchmark restored the original overlay afterwards.

Board logs are in `~/ax7020-a9-decode/results.ECdBzo/` (256) and
`~/ax7020-a9-decode/results.WVlfIP/` (1024). Host logs are under
`build/dual-board/a9-*` in the worktree.
