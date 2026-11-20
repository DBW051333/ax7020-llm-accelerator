# AX7020 Q8_0 LM Head streaming prototype

This is a standalone accelerator for the existing Qwen2.5-0.5B GGUF Head. It computes all 151,936 logits for one 896-element input. The four lane overlay reuses the 2017.4 PS and AXI DMA topology and its register addresses. It runs separately from the current v5 chat overlay.

## Data path

1. Read raw GGUF `token_embd.weight` rows without padding or requantization. The tied Head has 28 Q8_0 blocks of 34 bytes per row. A four-block group occupies exactly 17 64-bit AXI beats.
2. Each port streams an 8-byte header (little-endian magic `0x38444851`, then row count), followed by a 952-byte Q8_0 activation, then the weight rows. The prefix and weights use separate DMA transfers. Input TLAST marks a transport boundary. Output TLAST follows the final requested row.
3. A pair of weight group buffers lets the input fill a buffer while the eight-way signed dot product consumes the other. Activation blocks stay on chip for the tile. The existing exact two-scale accumulator rounds once to FP32 at the end of the row.
4. The host receives all logits, checks that lengths and values are valid, compares against CPU results and checks top-1. The host keeps up to four transmit tiles in XRT buffers and measures staging separately. The full-resident probe tries to retain the whole Head. If CMA prevents that, the hybrid experiment holds as many whole rows as fit and computes the tail on a CPU thread while PL is scanning. Hybrid staging happens once.

## Build and verification

Run `powershell -ExecutionPolicy Bypass -File compat/head2017/verify.ps1` from the repository root. The test drives two separate requests, four-block group boundaries, signed weights, zero/subnormal scales, input stalls and output backpressure. It compares each row bitwise against an independent Python reference.

Run Vivado 2017.4 in batch mode on `build/head2017/build_quad.tcl -tclargs all` from `build/head2017`. Use `HEAD_BUILD_TAG` for another independent implementation. Save the Vivado console as UTF-8 and check for `REBUILD2017-PASS`. Run `python compat/head2017/accept.py BUILD_DIR BUILD_CONSOLE` to create `accepted.json`. Check the two timing slacks and DRC before deploying.

Set `PYTHONPATH` to the pinned upstream `gguf-py` and run `make_fixture.py GGUF CPU_LOGITS FIXTURE_DIR`. `CPU_LOGITS` is a length-prefixed FP32 file from the earlier v5 CPU run. The script reconstructs three Q8_0 inputs by fitting 4,096 rows, then verifies the reconstruction on all 151,936 logits in each case. It is a validated reconstruction from captured inference outputs, rather than a direct dump of the hidden vector.

Deploy the accepted bit/HWH, `accepted.json`, `load_head.py`, `head_bench.c`, `head_cpu.inc`, `bench_board.sh`, and the fixture directory into an isolated board directory. Run `sudo bash bench_board.sh`. The script checks the model SHA256, compiles with Cortex-A9 NEON and warnings as errors, and tests two CPU threads, then HP0, HP0+HP1, HP0+HP2, all four HP ports, and resident/hybrid operation. It restores the v5 overlay on exit. The kernel, boot settings and v5 runtime need no edits.

## Acceptance and timing semantics

- Functional gate per case: full 151,936-row output, finite logits, max abs ≤ `5e-5`, relative L2 ≤ `1e-5` and matching argmax. This is operator acceptance for the three inputs, independent of whole-model quality.
- `dma_ms` includes prefix preparation, launching bursts, polling completion and output cache sync. In window mode it excludes staging and comparisons. `staging_once_ms` is one full traversal of the matrix for that run in window mode, reused for three verification inputs. Include it in any comparison to a single pass that has to refill its windows.
- `combined_ms` in hybrid mode is an upper bound that includes CPU tail, PL, and per-tile comparison overhead. Initial resident weight preparation is timed separately. `HEAD_SWEEP` is the actual wall time of the three-case sweep after resident initialization, including validation.
- First engineering target: 1.2 GB/s raw weight read on four ports. Compare the two dual-port mappings under equivalent transfers. Keep PL and CPU timing separate from input reconstruction and board boot.

## Board results, 2026-11-20

Vivado 2017.4 build at 83.33 MHz passed with WNS +0.563 ns and WHS +0.034 ns. Routed utilization was 27,882 LUTs, 19,362 FFs, 8 DSPs and 12 BRAM36 tiles. DRC reported zero errors or critical warnings. The loader verified both artifact hashes before programming. XSim passed 32 rows across two requests, including the injected stalls and transport boundaries.

| Mode | Full vocabulary time per input | Effective PL weight bandwidth |
| --- | ---: | ---: |
| Dual-core CPU reference | 305–331 ms | — |
| HP0 | 260.37–260.47 ms | 0.555 GB/s |
| HP0, HP1 | 140.76–140.83 ms | 1.027 GB/s |
| HP0, HP2 | 140.74–140.81 ms | 1.027 GB/s |
| HP0–3, windowed | 78.73–78.81 ms | 1.835–1.837 GB/s |
| HP0–3 + CPU tail, steady state | 105.31–118.02 ms | 1.811–1.820 GB/s on PL portion |

Windowed times exclude transferring the weights into the XRT buffers. One four-port staging traversal took 1,442 ms in this run. Full XRT allocation reached 18 of 22 tiles (122.831 MB of 144.643 MB), so it cannot run the entire Head with persistent PL buffers on the current 128 MiB CMA setup. In hybrid mode the 129,024 PL rows were preloaded once in 1,757 ms. The remaining 22,912 rows ran concurrently from the GGUF mapping on a CPU thread. The measured steady-state operator speedup was 2.81–3.07× against the respective two-core CPU cases, with no per-input weight staging in the hybrid path.

All modes returned all 151,936 logits for all three inputs with matching argmax (576, 12305, 374). Max absolute error versus the captured model CPU logits was `3.34e-6` for full-PL sweeps and `4.77e-6` for hybrid. Relative L2 was at most `1.36e-7` and `1.49e-7`, respectively. This experiment measured Head latency, not end-to-end chat TPS. Integrating the Head with v5/FFN into one overlay and adding the llama.cpp dispatch are separate implementation work. An all-PL steady-state implementation also needs a larger verified DMA pool or Linux DMA-mapped scatter/gather.[^logs]

The test restored v5 and reran its 8 real-weight cases and 100 zero-input repeats successfully, then checked the shared hardware lock was free.

[^logs]: Local logs are `build/head2017/board.log`, `build/head2017/rollback-smoke.log`, and `build/head2017/quad/{timing,utilization,drc}.rpt`. Demo files are in the board's `~/ax7020-head2017/` directory; model and logits fixtures are not tracked in Git.
