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
  GGUF fixture. Seal the accepted bit/HWH with the dual-clock seal script.
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
