# AX7020 Resident 1.202 board result

Board setup: AX7020 with PYNQ/Ubuntu 22.04, Vivado 2017.4, and 384 MiB CMA. Each repeat generated 24 tokens (23 timed decode evaluations), with the same prompt and GGUF, `-c 256 -b 64 -ub 64 -t 2 --temp 0 -s 1234 --no-warmup`. Runtime diagnostics were disabled for throughput measurement.

| Mode | Decode time | Token/s |
| --- | ---: | ---: |
| Staged Gate/Up, full PL Head, poll 50 | 25,078.77 ms | 0.917 |
| Resident Gate/Up, full PL Head, poll 50 (A) | 19,253.27 ms | 1.195 |
| Resident Gate/Up, full PL Head, poll 50 (B) | 19,004.60 ms | 1.210 |
| Resident Gate/Up, full PL Head, combined | 38,257.87 ms for 46 decode evaluations | **1.202** |

The fixture regression completed 8 real-weight cases and 100 zero-input repeats. The model ran 553 resident Gate/Up calls with no staging fallback and 24 full-vocabulary Head calls with no CPU rows. In the separate fixed-prefix comparison against the Gate/Up-enabled original projection path, all 24 sampled tokens matched, maximum absolute logit difference was 3.814697e-6, and relative L2 was 8.891202e-8. Free text matched on this prompt. CPU-only model parity and broader task quality were outside this comparison.

Combined overlay timing at 83.33 MHz: WNS +0.009 ns, WHS +0.025 ns. SHA-256 of the measured artifacts:

- Bitstream `37cf59e6d913d94a50750f299e48e26959c37c6eda99aa7f9050df62e3f1ceb1`
- Hardware handoff `c6487c45455d998c1efd37d643634b505b5e40f364b9eb442424d882dd67c1a3`
- Resident binary `19bcbf5af691c6a90b8a4ba5c8550a304c1c8888af6ec43ab7811a32432d67d8`
- Model `23c36f3a641c0062f5f60b1b98c652233a40adcc2c9f6c24df87d2e2b996248c`

Source and reproduction instructions are in [RESIDENT.md](RESIDENT.md).
