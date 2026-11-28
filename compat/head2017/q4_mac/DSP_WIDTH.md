# Para-MAC DSP width experiment

This experiment replaces the Q4_K Down LUT multiplier array with DSP48E1
multipliers. Build widths are 64 or 128 products across four lanes. The
64-wide mode operates on one accepted 64-bit weight beat at a time. The
128-wide mode banks the activations, collects two consecutive weight
beats, and scales their partial sums in parallel. Both modes use the
same 64-bit DMA links and Q4_K protocol. The 128-wide mode launches
once per two accepted weight beats. Gate/Up, Head, and the A9 NEON
application use their existing datapaths.

## Build and verify

- Restore the source snapshot and run
  `python compat/head2017/q4_mac/prepare_combined.py --dsp-width 64`
  and again with `--dsp-width 128`.
- Implement each generated `build/head2017/para-mac-dsp*` project with
  Vivado 2017.4 and `-mode batch -source build_quad.tcl`. Save the console
  as `implementation.log`. Check the timing and FIFO bus skew before
  sealing with `compat/head2017/dual_clock/seal.py`.
- Run `verify_combined.ps1 -BuildOutput BUILD -Model GGUF` and
  `dual_clock/verify.ps1 -BuildOutput BUILD -Axi 125 -Compute 100 -ScalePipeline`.
- On the board, place the sealed bit/HWH/JSON for each width in subdirectories
  named `dsp64` and `dsp128`. Copy `bench_dsp.sh`, `summarize_dsp.py` and
  `summarize_para.py` into their parent directory. With the existing
  Para-MAC deployment available and the board idle, run
  `sudo bash bench_dsp.sh 64 128`. The script checks 24 fixed-history
  steps and then alternates matching 48-token speed trials, before
  restoring Resident. The result directory is printed as RESULTS.
- Run `python3 summarize_dsp.py RESULTS 64 128` to pool the two timed
  samples per variant. The warm estimate skips the first four timed
  decode calls of each run.

## 64 products per cycle, LUT versus DSP

Both artifacts were tested at 125 MHz AXI and 100 MHz compute, with
384 MiB CMA, context 1024, a short story prompt, two threads and the
same application. The DSP implementation passed with +0.027 ns WNS
and +0.036 ns WHS. The routed cell map counted 108 DSP48E1 blocks,
64 of them Q4 product multipliers. LUT use fell from 49,930 to 48,191.
BRAM36 use remained at 84.

Both implementations produced identical tokens on the test prompt.
The DSP build matched 247,296 per-matrix values and all logits over
24 fixed-history steps exactly. The runs used all 12 Down matrices
without fallback and kept Gate/Up and Head fully resident.

| Build | DSP48E1 | LUT | Pooled TPS | Warm TPS |
| --- | ---: | ---: | ---: | ---: |
| Original Para-MAC, 64 products in LUT | 44 | 49,930 | 1.4760 | 1.5900 |
| Para-MAC, 64 products in DSP | 108 | 48,191 | 1.4590 | 1.5970 |

Each variant used two 47-step decode trials. Warm TPS pools 43 steps
per trial. The 0.44% warm increase was small and the four median step
times ranged from 638.36 to 639.30 ms. The migration relieved LUT use.
The full recorded run, including initialization costs incurred during
decode, was 1.15% slower in the DSP build. Evidence is in
`build/para-dsp-board.log` and the routed DSP map under
`build/head2017/para-mac-dsp64/dsp-map.log`.

## 128 products per cycle feasibility

The original 128-wide variant failed packing under both the default
and Explore placement strategies. A RAM-style hint was ignored in
synthesis because the inferred activation memory was incompatible
with block RAM. The next variant uses explicit XPM block RAM with
the same one-cycle read latency and the same packet format. To build
it, pass `--dsp-width 128 --block-activations` and use the resulting
`build/head2017/para-mac-dsp128-xpm` directory. The XPM variant passed
the same Q4_K, Gate/Up, Head and scaler simulation suites.
