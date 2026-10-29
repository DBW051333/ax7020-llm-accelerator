# AX7020 LLM PL Accelerator

For agents sharing this project, start with [AGENTS.md](AGENTS.md) and the [shared project context](docs/PROJECT_CONTEXT.md). They describe the archive layout, evidence status, known documentation conflicts, and handoff conventions.

Private project snapshot for the ALINX AX7020 / Zynq-7020 board. The primary reproducible hardware baseline is the **four-instance B-Lite overlay**. The Q5_0/Q8_0 exact-scale path is included as experimental source and is not the deployed board baseline.

## Delivery contents

The full source snapshot is stored as numbered 600 kB parts in `source/`. Reassemble and unpack it from a fresh clone:

```bash
sha256sum -c source/PARTS.sha256
cat source/ax7020-source.tar.xz.part-* > ax7020-source.tar.xz
sha256sum -c source/SHA256SUMS
tar -xJf ax7020-source.tar.xz
cd ax7020-llm-accelerator
```

The archive contains the RTL, Vivado Tcl/IP/BD sources, constraints, testbenches and vectors, board-side C/Python programs, model-integration patch, reports and handoff documents. It omits Vivado caches, generated netlists, run databases, duplicate logs and machine-local project files. The bitstream and XSA for the board-tested four-instance overlay are retained.

## Rebuild the deployed overlay

For the local **Vivado 2017.4** compatibility rebuild, use [the compatibility flow](compat/vivado2017/README.md). It restores the immutable archive, applies isolated RTL/tool adaptations, runs XSim checks, and creates a separate four-instance project. This is a port with its own validation record, not a reuse of the 2025.2 implementation results.

A separate [Gate/Up + SiLU/multiply fusion experiment](compat/gateup2017/README.md) has now been rebuilt with 2017.4 and tested on the board. The short-sequence test measured about 0.667 token/s versus 0.544 CPU and 0.547 for the Q4 baseline. Local numerical checks pass, but CPU/PL generated text differs; model quality equivalence is unqualified. See the [measured results and limitations](docs/gateup2017/RESULT.md). The original four-instance B-Lite baseline is preserved.

Host prerequisites: Vivado 2025.2 with Zynq-7000 support and the AX7020 device files. Then run:

```bash
cd rtl
vivado -mode batch -source bd_dma_quad.tcl
```

The script creates `blite_sys_quad.xsa`, runs implementation through bitstream generation, checks the AXI stream wiring and requires non-negative setup and hold slack before export. Implementation can take tens of minutes. The committed `rtl/blite_sys_quad.xsa` and `artifacts/blite_quad_wrapper.bit` are the last recorded working artifacts for the four-instance design; a rebuilt bitstream can differ in placement while preserving function.

For RTL simulation, use Vivado 2025.2 `xvlog`, `xelab`, and `xsim`; command examples and expected PASS markers are in `交接指南.md` and the verification documents.

## Board and software prerequisites

- ALINX AX7020 board with a compatible Zynq-7000 Linux/PYNQ image, working JTAG/PCAP and four enabled HP ports. The OS/SD-card image is not redistributed here.
- Use the documented PYNQ overlay load path for the `.xsa`; do not program the Zynq fabric with raw JTAG because PS initialization and FCLK setup are required.
- The board-side sources are under `board/`, `integration/`, and `experimental/q58_runtime/`. Cross-compilation uses the ARM GNU toolchain described in `移交文档.md`; toolchain installers are not included.
- Model weights are external inputs. The small real-weight test fixture in `data/` is included; full GGUF model files are not.
- Configure `BOARD_IP`, SSH credentials/keys, and any board `sudo` policy locally. Credentials and the original board's private IP are intentionally not stored in this repository.

## Recorded validation

The handoff records four-instance board bring-up, timing closure at 83.33 MHz, a 3.4677 GMAC/s synthetic workload result, and a real-model 24-token run whose generated text matched the CPU output byte-for-byte (reported end-to-end rate: 0.60501 versus 0.59346 token/s). These are historical measurements tied to the stated board, software image, model and test setup; they are not a promise that a new setup will reproduce the same performance. See `移交文档.md`, `docs/资源并行提速.md`, and `docs/真实模型接入.md` for details and caveats.

The Q5_0/Q8_0 exact-scale engine and its llama.cpp integration are experimental: source-level tests and analysis exist, but complete overlay implementation and fresh-board behavior were not established in the handoff.
