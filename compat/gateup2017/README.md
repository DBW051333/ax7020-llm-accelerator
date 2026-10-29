# Gate / Up / SiLU / multiply fusion experiment (Vivado 2017.4)

This is a separate four-lane experimental overlay. The delivered B-Lite Q4 baseline and its production executable are preserved. In this experiment only eligible Qwen Q5_0 Gate/Up pairs and their SiLU/multiply are dispatched to PL; Down, attention and other operations run on CPU. The Q5 projection engine derives from the archived Q58 exact-scale experiment, whose historical claims do not substitute for the checks here.

## Hardware and numerical contract

Each lane receives one Q8_0 activation, then Q5_0 Gate and Up rows. Gate/Up share the activation in BRAM. Each output row is `SiLU(gate_dot)*up_dot`, returned as F32 in a 64-bit beat. Four lanes split the output rows. Each Q5 dot uses exact integer arithmetic and FP16 scale products with a wide accumulator, rounded once to F32. This can differ from the CPU's intermediate floating accumulation.

SiLU uses a sigmoid ROM at steps of 1/256 over magnitude [0,32], Q30 probabilities, linear interpolation, a Q20 coordinate, and saturated tails. Two finite IEEE F32 RNE multiplications compute Gate×sigmoid and then ×Up. This is an explicit approximation, not an exact implementation of ARM `expf`. The acceptance checks include independent mathematical vectors, real model weights, same-input CPU reference checks, and separately reported model logits/text. Passing local numerical tolerance is not model quality acceptance.

Packet header low byte `0x58`, next byte format `21`, bits31:16 lane rows, bits47:32 K/32. Each activation block is raw34 bytes padded to40. For each output row, all Gate blocks (raw22 padded24) precede all Up blocks. Input TLAST marks the DMA packet; the validated header determines the internal payload length. One output per row; final output has TLAST. Raw formats5/8 remain available for diagnostic compatibility.

## Host build

```powershell
python tools/restore_source.py
powershell -ExecutionPolicy Bypass -File compat/gateup2017/verify.ps1
python compat/gateup2017/receipt.py
python compat/gateup2017/prepare_build.py
$env:GATEUP_BUILD_TAG='quad-2017-v4'
& D:/Xilinx/Vivado/2017.4/bin/vivado.bat -mode batch -source compat/gateup2017/build_quad.tcl -tclargs all
python compat/gateup2017/audit.py
```

The build binds the RTL and test inputs to successful simulation hashes and refuses to export if final setup or hold slack is negative. Reusing a project is refused for a full build; use a new build tag for a new revision. Failed timing attempts remain in their original build directories and `failed-v*/`; they are not accepted hardware. The revised multiplier registers input, normalization, product, alignment and rounding, and uses hierarchical normalization. Sigmoid interpolation and conversion also use explicit pipeline stages. Frequency remains 83.333MHz, period12ns.

`prepare.py` derives RTL from immutable sources and generates the sigmoid ROM. `vectors.py` uses a fixed seed to generate finite IEEE multiplication cases, activation boundary/random cases, and matrix packets including K896, K8192, zero/freshness cases, source pauses and output backpressure. `verify.ps1` requires all three PASS markers and no fatal errors. Full logs remain under ignored `build/gateup2017/`.

## Software and board deployment

`prepare_software.py` emits pinned upstream source changes: a shaped F32 custom operation with three explicit graph dependencies, an opt-in single-column Gate/Up fusion branch, a runtime callback using the existing CPU Q8_0 quantizer, build integration, and optional raw-logits/forced-token diagnostics. LoRA, different shapes/types, multi-column graphs and biased/scaled FFNs keep the original path. Unsupported shapes stay on CPU; failure after a supported hardware dispatch aborts rather than silently falling back.

It requires the pinned patched upstream source previously prepared by `tools/prepare_validation_bundle.py`. After the host hardware build and source preparation:

```powershell
python compat/gateup2017/prepare_software.py
python compat/gateup2017/bundle.py --model <exact-GGUF-path>
python compat/gateup2017/accept.py --tag quad-2017-v4 --log build-v4.log
```

Deploy `software.tar.gz` to the separate board directory and extract with `tar -xmzf`; do not replace model weights or the production executable. The deployment expects the existing validated model path and pinned native build tree described in the shared context. Copy the accepted bit/HWH pair and `accepted.json` into `overlay/` before loading. The first load must follow resource/process checks and completion of the baseline tests. `run.sh` explicitly loads the matching accepted overlay before manual chat.

The current selected shape is K896, rows4864. On the 8-token prefill, the final Transformer layer is compacted to one output column and is also eligible. A 24-token test with23 decode steps therefore makes553 calls:552 decode calls plus1 prefill call. Each call computes both matrices and the activation product. `BLITE_GATEUP_VERIFY=1` independently recomputes each supported fused result from the same quantized input using CPU Q5 vec_dot and `expf`, enforcing relative L2<=1e-4. This mode is excluded from timing.

The runtime stages at most8MiB TX and48KiB RX across four lanes, with a bounded192MiB ordinary-DDR packed weight cache (not persistent PL weight storage). It holds `/tmp/blite-perf.lock`, arms receive before send, checks both IOC/error flags and receive length, and frees buffers/reset DMA on ordinary process exit. A hardware error requires stopping and reloading the full overlay, not retrying a partial packet.

`build_board.sh` targets the existing pinned native build tree after verifying and backing up every affected source file. It copies the new executable to a separate deployment directory and restores the source on exit. Existing build objects/cache remain experimental; rebuild from restored sources before producing a baseline executable. The old production binary is not overwritten. Host-specific SSH credentials are process environment only.

`test_baseline.sh` runs before changing the loaded overlay: new-binary CPU diagnostic baseline, then old-binary Q4 performance baseline. After a timing-accepted overlay load, run real-weight tests, then `test_model.sh`: fused free performance generation twice, CPU-forced full numerical verification/logits, CPU diagnostic repeat, and CPU performance without logits capture. Performance runs disable numerical verification, profiling and raw-logits writes. It requires hardware call counts and repeat checks, and reports text parity separately. Diagnostic logits files and forced histories are retained. No speedup should be described as quality-preserving without a matching quality evaluation.

Use `BLITE_GATEUP=1 BLITE_ENABLE=0 BLITE_Q58=0` only with this overlay. The old Q4 program with `BLITE_ENABLE=1` requires the original overlay. Do not mix protocols at the same DMA addresses.
