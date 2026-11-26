# AX7020 dual-clock Resident experiment

The four AXI DMA paths, HP interfaces and AXI interconnect use FCLK0. Each
lane has two independent-clock AXI4-Stream Data FIFOs between the DMA and
the compute domain on FCLK1. Both domains derive their reset from the
PS reset and synchronize release in their own domain. The FIFO is in word
mode so a prefix transfer's TLAST can reach the core before its weight
transfer. The DMA addresses and Resident software packet format are unchanged.

The new pointwise multiply-reduce pipeline separates the eight-product
integer sum from the block accumulator. The optional scale pipeline splits
FP16 scale multiplication, alignment, 112-bit accumulation and rounding.
The experiment retains the released formats and full-vocabulary logits.

## Build and verify

1. Run `python tools/restore_source.py` from the repository root.
2. Run `powershell -ExecutionPolicy Bypass -File compat/head2017/dual_clock/build.ps1 -Axi 125 -Compute 200`
   with Vivado 2017.4 installed at the default path, or pass `-VivadoBin`.
   The script generates the block design, runs a mixed-packet/stream-stall
   test using the generated Xilinx FIFO models, and implements the design.
   Numerical clock arguments are target MHz. The PS may round slightly to
   an achievable divider value. Verify both actual frequencies in the
   block design and HWH. Use `-LegacyScaler` for the dot-only variant.
3. Check `quad/timing.rpt`, `quad/clock_interaction.rpt`, `quad/cdc.rpt`,
   and `quad/drc.rpt`. An implementation acceptance marker and the hashes
   in `quad/accepted.json` are required for the board test. A negative-slack
   build has no accepted overlay in the export directory.
4. On a board with the Resident release and 384 MiB CMA, copy the accepted
   `head_quad_2017.bit`, `head_quad_2017.hwh`, `accepted.json`,
   `load.py`, `bench_board.sh` and the parent `compare_decode.py` to
   a separate directory. Run `sudo bash bench_board.sh` when the board is idle.
   It loads the released overlay and candidate in sequence, checks DMA,
   compares fixed-history logits, measures free decode, and restores the
   released overlay on exit. `--baseline` only measures the released overlay.

Generated Vivado projects, hardware binaries and measurement logs are
kept under `build/head2017/dual-clock-*` and `build/dual-board/`.
