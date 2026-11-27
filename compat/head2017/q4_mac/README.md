# 64-MAC and 128-MAC Q4_K laboratory overlays

Both overlays use four 64-bit DMA lanes at 125 MHz and compute at 100 MHz.
Each lane performs 16 products per column per weight beat. The dual-column
overlay broadcasts one weight beat to two independent activation banks and
pipelines the two integer reductions in parallel.

The fixture uses one Q4_K Down matrix from the local GGUF, split into four
equal row ranges. Activations are deterministic signed Q8 test vectors.
The numerical reference independently decodes the GGML nibble order and the
six-bit scales. Each output beat holds a signed scaled integer sum per
column for one 256-weight superblock. The fixture includes signed extrema.
The result stops at the integer stage. The GGML min correction and ordered
FP32 accumulation, graph integration, candidate generation and KV commit
are later integration work. The DMA results are matrix-only measurements.

## Reproduce

1. Restore the snapshot with `python tools/restore_source.py`. Run
   `compat/head2017/q4_mac/verify.ps1 -Model PATH_TO_GGUF` to compare two
   packets per mode against the reference under randomized stream stalls.
2. Run `python compat/head2017/q4_mac/prepare.py 1` or use `2` for two
   columns. In the resulting `build/head2017/q4-mac-*` directory, run
   Vivado 2017.4 in batch mode with `-source build_quad.tcl` and save
   the console log. Seal the output with
   `python compat/head2017/dual_clock/seal.py BUILD/quad BUILD/implementation.log`
   (invoke from the repository root) and save its JSON as `accepted.json`.
3. From the root, run
   `python compat/head2017/q4_mac/fixture.py 1 --model PATH_TO_GGUF --board fixture.npz`
   with the matching column count. Copy the fixture, `board_test.py`,
   and sealed bit/HWH/JSON files to a new board directory. With the board
   idle and the normal Resident restore script present, run with the
   PYNQ virtual environment as root and `XILINX_XRT=/usr`:
   `python board_test.py OVERLAY_DIRECTORY fixture.npz`.
4. The board test takes the DMA lock, validates clocks and artifact hashes,
   checks the S2MM length and all results, and restores the original
   Resident overlay on exit. It reports a cold sample and 20 warm DMA
   samples. Timings include MM2S cache flushes, S2MM invalidation, and
   Python DMA dispatch. Host-side packet creation is outside the timer.

A full single-chat trial requires both columns to traverse the full model.
For one draft token and greedy verification, one round emits one token
plus a second token when the draft agrees. A measured round time including
draft and rejected-state handling must be below the single-column
per-token time multiplied by the average emitted tokens per round.

## AX7020 results on 2026-11-28

Both modes passed Vivado 2017.4 XSim on real GGUF weights with random
input gaps, output backpressure and two consecutive packets. Both routed
at 125/100 MHz and read back those clocks on the board. The board test
checked all 17,024 superblocks in each active column for each of 21 runs.
All values matched the integer reference exactly.

| Configuration | WNS / WHS (ns) | LUT / BRAM36 / DSP | First run (ms) | Median of 20 warm runs (ms) |
| --- | --- | --- | ---: | ---: |
| 64 MAC, one column | +0.823 / +0.036 | 16,847 / 12 / 4 | 3.859 | 3.593 |
| 128 MAC, two columns | +1.318 / +0.033 | 19,407 / 20 / 8 | 3.722 | 3.399 |

The input was 2,334,720 and 2,354,176 bytes respectively. Both returned
136,192 bytes because the one-column packet uses the same output slot
size. Two columns in 3.399 ms are equivalent to 1.700 ms per column
for this benchmark. The approximately 2.11x matrix-column rate includes
a 0.194 ms difference in wall time between two separate bitstreams.
There was one session per configuration, so the small difference in
absolute run times is not a repeatable latency claim. These resource
totals belong to the laboratory overlay. A combined design with
Resident Gate/Up and Head requires its own implementation report.

Local evidence is under the worktree's build directory in
q4-mac-board-1.log, q4-mac-board-2.log and q4-mac-restored.log.
The original 83.33 MHz Resident overlay was restored after each test.
The final check found FPGA operating, CMA 384 MiB and the DMA lock free.
