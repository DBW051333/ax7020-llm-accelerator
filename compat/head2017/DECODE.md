# Gate/Up and resident LM Head integration

The combined overlay keeps the v5 Gate/Up arithmetic and augments each of the four AXI DMA lanes with a Head endpoint. The lane selects the endpoint when its first header is accepted and holds it through output TLAST. A Head request can therefore use separate MM2S transfers for the activation prefix and resident weights. The standard Gate/Up packet and DMA addresses are unchanged.

The firmware applies Head acceleration only to the Qwen2 output projection with a contiguous single-column F32 input and the exact Q8_0 weight shape `896 × 151936`, with no LoRA adapter. Other graphs use the upstream output projection. Gate/Up and Head share the XRT device, DMA registers and hardware lock. The runtime uploads as many Head tiles as the existing pool can hold once per process, without touching the boot configuration. It starts a CPU tail worker in parallel with each PL scan and writes both ranges into the same logits vector. Use `BLITE_HEAD=0` to select the original CPU output projection.

1. From the repository root run `powershell -ExecutionPolicy Bypass -File compat/head2017/verify.ps1 -Combined`. XSim alternates the two packet formats under input stalls and output backpressure.
2. Run Vivado 2017.4 on `build/head2017/decode/build_quad.tcl -tclargs all`. Use `accept.py` on the resulting `quad` and console log to create `accepted.json` after timing and DRC pass.
3. Use a fresh board directory. Upload `build_decode_board.sh`, `head_cpu.inc`, `head_runtime.inc`, `head_callback.inc`, and run `bash build_decode_board.sh` as the normal board user. It checks the installed v5 source and the pinned baseline hashes, copies sources, then builds a separate binary. The native build can take over 15 minutes. Use `bash build_decode_board.sh --resume` to resume an interrupted compilation after source preparation has completed.
4. Upload both hardware files, the receipt, `load_head.py`, `test_decode_board.sh`, `compare_decode.py`, and `run_decode.sh`. Run `sudo bash test_decode_board.sh` with the device idle. The script runs the existing Gate/Up DMA regression, compares 24 complete vocabularies on identical forced histories, and measures two runs per backend without diagnostics. A failed validation reloads the known v5 overlay.
5. The measured difference between the hybrid Head and the previous four-port full-PL scan gives a practical estimate of the incremental gain from expanding DMA memory. Consider the observed whole-model decode cost and startup cost before changing the SD boot configuration.

## Integrated board results

The 2026-11-20 Vivado 2017.4 implementation passed at 83.33 MHz. WNS was +0.009 ns and WHS was +0.025 ns. Routed utilization was 44,462 LUTs (83.58%), 24,766 FFs, 84 BRAM36 and 40 DSPs. The board passed the Gate/Up 8-case matrix and 100 zero-repeat tests on this bitstream. The standalone Head smoke test also returned the expected complete vocabulary on the combined bitstream.

Using the same binary, exact model, prompt and greedy settings for both modes:

| Mode | Decode run A (23 steps) | Decode run B (23 steps) | Pooled token/s |
| --- | ---: | ---: | ---: |
| PL Gate/Up, CPU Head | 31.282 s | 30.912 s | 0.7396 |
| PL Gate/Up, resident hybrid Head | 27.302 s | 26.213 s | 0.8596 |

The measured decode improvement is **16.2%**. The Head runtime allocated 17/22 tiles, with 121,856 rows on PL (80.2%) and 30,080 rows on CPU. `HEAD-STATS` reported about 161 ms per application excluding the one-time upload. The upload took 1.26–1.54 s in those performance runs. Measured prompt eval grew by about 1.17 s on average. One diagnostic run incurred 4.84 s in the Gate/Up first-pack statistic and was slower than its matched diagnostic baseline. Diagnosis and performance runs are therefore reported separately.

The paired forced-history check covered 24 × 151,936 logits. Maximum absolute difference was 6.68e-6, relative L2 was 1.05e-7, and all 24 sampled and argmax token IDs matched. Free generation text matched across modes and repeated runs on this prompt. The CPU-Head output also matched the previous v5 board run. This compares two Gate/Up-enabled paths and does not claim CPU-only model parity or general task accuracy.

**DMA memory decision:** retain the current 128 MiB CMA. Substituting the isolated 79 ms scan for the integrated 161 ms Head gives an optimistic 0.925 token/s, about +7.6% / +0.065 token/s over hybrid, before accounting for integration overhead or additional allocation and prefill costs. That projected gain does not justify reserving more boot-time memory for this deployment. Revisit with the planned DDR mapping redesign or after other operators leave the critical path.

Follow-up: the [resident runtime](RESIDENT.md) later demonstrated sufficient gain to justify the 384 MiB profile by eliminating weight staging across all 24 Gate/Up layers as well as the Head CPU tail. The figures above describe the earlier Head-only changes.

The validated combined overlay is left loaded and the hardware lock is free. The optional manual entry point is `cd ~/ax7020-decode2017 && bash run_decode.sh`. The original v5 program remains available in `~/ax7020-gateup2017`.

Evidence: `build/head2017/decode/{model-ab.log,combined-smoke.log,board-build-resume.log,quad/accepted.json}` and board `~/ax7020-decode2017/decode-logs.2xCPGS/`.
