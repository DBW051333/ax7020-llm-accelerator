# Para-MAC single-chat experiment

This integrates the four-lane 64-MAC Q4_K integer datapath into the
125/100 MHz Resident design. A distinct request header routes matching
single-column FFN Down operations through the new lane. The A9 NEON
runtime still handles the Q6_K Down matrices and attention projections.
The FPGA keeps the original Gate/Up and Head engines. ARM reconstructs
the Q4_K correction and applies the ordered FP32 scale/accumulate.

The 128-MAC laboratory overlay verifies two simultaneously supplied
activation columns. The single-chat runner executes ordinary autoregressive
decoding. It uses the 64-MAC single-column engine in the combined overlay.

## Reproduce

- Run the source restore tool and then
  `python compat/head2017/q4_mac/prepare_combined.py`. Use the generated
  `build/head2017/para-mac/build_quad.tcl` with Vivado 2017.4 in batch mode
  and save the output in `implementation.log`.
- Run `compat/head2017/q4_mac/verify_combined.ps1` and run
  `compat/head2017/dual_clock/verify.ps1 -Axi 125 -Compute 100 -ScalePipeline -BuildOutput build/head2017/para-mac`
  after the BD outputs exist. Pass `-Model` to the former to check a real
  GGUF fixture. Run the dual-clock bus-skew check and seal the accepted bit/HWH with the dual-clock seal script.
- Place the sealed files in an isolated board directory named `overlay`.
  Install the Para-MAC build, loader, comparison and shell scripts and
  `resident_gateup.inc` from the parent directory beside it. Run
  `python3 build_para.py` on the board against the installed A9 NEON and
  Resident build trees. It creates separate binaries and archives.
- Run `sudo bash bench_para.sh` when the board is idle. The fixed-history
  check requires exact matrix outputs, exact full logits and complete
  resident coverage before the ABBA timed runs. The two timed variants
  share the same bitstream and executable. Only BLITE_PARA_MAC differs.
- For interactive use, run `bash run_para.sh` in the installed directory.
  This loads the combined overlay and takes optional llama-cli arguments.

## On-board single-chat results

The initial routing estimates showed -0.033 ns WNS. The original
implementation's final timing report accepted 125 MHz AXI and 100 MHz
compute at +0.007 ns WNS and +0.034 ns WHS. The tested bit has SHA256
080e88b64edbfc422dedb1d507b1cf5bcfbc06ec277e534e23dab03ab86449e7.
All 16 FIFO bus-skew checks passed. The build uses 49,930 LUTs (93.85%),
84 BRAM36 and 44 DSP. The board clock readback was 125/100 MHz.

At 384 MiB CMA, the diagnostic covered 276 Q4_K Down dispatches across
all 12 matrices. All 247,296 values matched the A9 reference exactly.
All 151,936 logits matched bitwise on each of 24 fixed-history steps.
Gate/Up and the Head remained fully resident. Timed outputs matched
across all four free-generation runs.

Both modes used the same binary and bitstream with context 1024, two
threads, greedy sampling and the prompt "Write a short story about a
robot." Timing excludes model loading and prompt eval. Each mode ran
two samples of 63 decode steps. The warm measurement omits four initial
decode calls in each sample, for 118 counted calls per mode.

| Down path | Eval ms (two runs) | Pooled decode TPS | Warm decode TPS |
| --- | --- | ---: | ---: |
| CPU A9 NEON | 46,443.84 + 44,342.75 | 1.388 | 1.470 |
| 64-MAC PL | 43,605.63 + 42,799.32 | 1.458 | 1.564 |

Para-MAC gained 5.07% over the pooled run and 6.45% in the later steps
(41.22 ms/token net). Para-MAC recorded about 14.04 ms/token of DMA and
33.36 ms/token of ARM reduction. Both timed Para-MAC runs had 756
offloads and zero fallback. This qualification covers single-column
generation with the tested prompt.

Two preliminary launches overlapped during artifact qualification.
They were discarded after a DMA-lock conflict and the complete ABBA
sequence was repeated under a dedicated benchmark lock. The accepted
results are in the board directory results.para.WwDgiX and local
build/para-final-board.log. After the accepted run, the original
83.33 MHz Resident overlay was restored. FPGA operating state, free
DMA lock and the original 384 MiB CMA were verified.
