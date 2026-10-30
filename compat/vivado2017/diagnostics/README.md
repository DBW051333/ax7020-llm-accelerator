# CPU/PL fixed-token diagnosis

This is a diagnostic experiment, separate from model acceptance and timing. It preserves the failed 24-token robot prompt and all earlier validation logs. The production `bin/llama-cli-blite` is not replaced.

`prepare_trace.py` reads the pinned, patched upstream snapshot under `build/upstream/` and emits instrumented `main.cpp` and `ggml-cpu.c` under `build/logits-diagnosis2017/source/`. The immutable `accel/` snapshot is never changed. Before building on the board, save its two original source files under `diagnosis2017/baseline/`, verify their hashes match the local pinned source, upload the generated files into their respective source locations, incrementally build target `llama-cli`, and copy the resulting executable to `bin/llama-cli-diagnostic`. Restore the saved source files after building. The build tree now contains diagnostic objects; rebuild from the restored source before using it to produce a release binary.

Upload `run_trace.sh` as `diagnosis2017/run_trace.sh` in the existing deployment directory, confirm the board and hardware lock are available, then run:

```bash
cd /home/xilinx/ax7020-validation2017
sudo env XILINX_XRT=/usr bash diagnosis2017/run_trace.sh
```

The script refuses to overwrite existing diagnostic logits. Use a separate run directory for a new experiment. It runs four serial modes: CPU; PL with CPU-forced history; PL with CPU-forced history and explicit per-layer CPU reference substitution; CPU repeat. All use the same executable, model, prompt, context, batch, threads and greedy sampler. The third mode executes hardware but replaces Q4 outputs for causal localization; it must never be presented as hardware numerical equivalence or acceleration.

Each `.logits` record is little-endian `uint32 vocab_size` followed by that many raw float32 logits, captured before sampling. `.tokens` has `sampled_id forced_id` per generation step. `.matvec` records contain four uint32 values `(name_bytes,k,rows,q8_bytes)`, UTF-8 layer name, `k` F32 input values, packed Q8_K input, `rows` hardware/CPU output floats, and `rows` same-input CPU vec_dot reference floats. Trace records are written before reference substitution. Sampling step 0 is the prompt's next-token prediction; Q4 trace records start at decode step 1, after the first generated token is fed back.

Retrieve the logs to `build/logits-diagnosis2017/logs/`, then run on the host with NumPy and the pinned upstream `gguf-py` package available:

```powershell
python compat/vivado2017/diagnostics/analyze_trace.py --model <exact-GGUF-path>
```

The analyzer verifies equal forced histories, bitwise CPU repeat logits, greedy sampling versus raw argmax, and the expected 12 Q4 layers per decode. It reports full-vocabulary errors, top candidates and raw softmax probabilities, CPU/PL candidate margins, first Q4 output difference, first changed Q8 integer code, and the reference substitution result. Raw softmax probabilities are descriptive; temperature-zero generation chooses the argmax. Full raw diagnostics remain in ignored `build/`; a compact report and hashes are saved under `docs/` after actual testing. Instrumented run times are not performance measurements.

`check_rtl_arithmetic.py --model <exact-GGUF-path>` independently replays the first captured Q4 matvec using integer models of the RTL's truncating FP multipliers, Q18 coefficient conversion, integer MAC, final truncating FP conversion, and runtime power-of-two scaling. It compares all 896 output rows bitwise with the captured hardware output. This is an arithmetic check for one captured input, not a protocol/state-machine simulation or a global model quality evaluation.
