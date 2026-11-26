# AX7020 dual-clock Resident experiment

See [the board and timing results](RESULT.md) for the validated 125/100 MHz profile.

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

## Reproduce the tested 125/100 MHz profile

The 125/200 MHz implementation with the new scaler routed but missed timing
at 200 MHz. For the board test, the same routed design was timed again at
100 MHz on FCLK1. The tool checks that the generated 100 MHz HWH differs
only in the FCLK1 metadata and that both builds have identical RTL and ROM.
It preserves the original placement, clock exceptions and FIFO pointer
constraints, checks setup, hold and bus skew, then produces a hash receipt.

After running the 125/200 build below and retaining its routed checkpoint:

```powershell
python compat/head2017/dual_clock/prepare.py --compute 100 --scale-pipeline
Push-Location build/head2017/dual-clock-125-100-pipe
& D:/Xilinx/Vivado/2017.4/bin/vivado.bat -mode batch -source build_quad.tcl -tclargs bd
Pop-Location
& compat/head2017/dual_clock/verify.ps1 -Compute 100 -ScalePipeline
python compat/head2017/dual_clock/requalify.py build/head2017/dual-clock-125-200-pipe build/head2017/dual-clock-125-100-pipe build/dual-board/recheck100
```

Use the bit/HWH pair and receipt from `build/dual-board/recheck100` for the
board procedure below.

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
