# Dual-clock board results

Vivado 2017.4, XC7Z020-2, AX7020 with 384 MiB CMA, Resident binary and
Qwen2.5-0.5B Q4_K_M. The four DMA/HP paths use 125 MHz in all new designs.
The original reference uses one 83.33 MHz clock for DMA and compute.

## Implementation

| DMA / compute (MHz) | RTL | Global WNS / WHS (ns) | Outcome |
| --- | --- | ---: | --- |
| 125 / 200 | Pipelined dot, original scaler | -6.021 / +0.023 | Failed setup |
| 125 / 200 | Pipelined dot and scaler | -4.661 / +0.025 | Failed setup |
| 125 / 142.857 | Pipelined dot and scaler | -2.910 / +0.021 | Failed setup |
| 125 / 111.111 | Pipelined dot and scaler | -0.837 / +0.048 | Failed setup |
| 125 / 83.33 | Routed dot-only build requalified at reduced FCLK1 | +0.709 / +0.023 | Board passed |
| 125 / 100 | Routed dot-and-scaler build requalified at reduced FCLK1 | +0.256 / +0.025 | Board passed |

At 125/100, compute setup slack is +0.339 ns. The overall WNS is in the
125 MHz domain. The build uses 43,040 LUTs (80.90%), 30,299 registers,
84 BRAM36 and 40 DSP48E1. Setup, hold, pulse-width and the 16 FIFO
pointer bus-skew constraints passed. The CDC warnings refer to the
Xilinx FIFO pointer and clock-enabled memory structures. There were
no CDC Critical entries.

The 200 MHz critical path moved from the original scaler's normalization
and rounding to Gate/Up's header-derived weight-word counter. Other near
critical paths include the Head bank/operand multiplexers into the DSP and
the SiLU FP32 multiplier's product-to-rounding stage.

## Functional checks and throughput

The 125/100 build passed XSim with the generated vendor FIFO wrappers
(4,102 input words, 38 output rows, input TLAST and randomized backpressure).
A separate exact-integer oracle passed 512 rows and 2,281 scaled blocks.

Both board profiles passed 8 real Gate/Up inputs and 100 zero repeats.
The worst Gate/Up relative L2 against the matrix fixture was 2.97e-7.
Head passed 3 full-vocabulary fixtures, and all 24 fixed-history vocabulary
logit vectors matched the original Resident overlay bit for bit. Free
generation matched on the test prompt. Throughput runs used 24 generated
tokens, 23 timed decode calls each, context 256, batch/microbatch 64,
two threads, poll 50, greedy sampling and the same prompt and binary.
The baseline and candidate each ran twice in every row.

| A/B candidate (MHz) | Baseline decode ms (two runs) | Candidate decode ms (two runs) | Pooled decode token/s | Head scan (GB/s, 3-case mean) |
| --- | --- | --- | --- | --- |
| 125 / 83.33 | 22544.89 + 20841.27 | 20479.22 + 19363.06 | 1.060 to 1.155 (+8.9%) | 1.839 to 2.036 (+10.8%) |
| 125 / 100 | 20890.66 + 19326.53 | 19505.44 + 19526.68 | 1.144 to 1.179 (+3.0%) | 1.837 to 2.067 (+12.5%) |

These are paired measurements with two repeats per side. The magnitude of
the speedup is sensitive to cold weight setup and other CPU-side costs.
The 125/100 candidate repeated closely within its pair. Gate/Up DMA time
under its fixture was roughly unchanged (449.446 to 450.522 ms over
108 calls). The 125/83 candidate had slower Gate/Up DMA for that fixture
(449.252 to 534.123 ms) despite faster Head scans. No long-prompt or
multi-column inference result is claimed.

## Artifacts and recovery

At 125/100 MHz, PYNQ read back 124.999999 and 99.999999 MHz. Accepted
artifacts SHA-256:

- Bit: f2a2b2923b7881658740ce38a51bcf55a8ee24bae0f33bae4f5dde677e67313f
- HWH: e7f32a05c5e72950854b9e7573d1b1c50936399c54bbda921983bbdb1eb6847d

Local results are under `build/dual-board/recheck{83,100}*` and the build
reports under `build/head2017/dual-clock-*`. Board runs are in
`~/ax7020-dual-clock/results.QVyvgD` and
`~/ax7020-dual-clock-100/results.th3GB2`. The harness restored the
accepted 83.33 MHz Resident overlay after each test. Build and rerun
commands are in [README.md](README.md).
