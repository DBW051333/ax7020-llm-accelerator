"""Relink the Resident program with ARMv7-only K-quant kernels."""
import hashlib
from pathlib import Path
import re
import shlex
import shutil
import subprocess

here = Path(__file__).resolve().parent
home = Path("/home/xilinx")
base = home / "ax7020-decode2017"
resident = home / "ax7020-resident2017"
build = base / "llama-build"
src = base / "llama.cpp/ggml/src/ggml-cpu/ggml-cpu-quants.c"
expected = "dc1e2486053578e00ae490b81bc48fe59a9fa226147db60825b5c28f92450ae6"
if hashlib.sha256(src.read_bytes()).hexdigest() != expected:
    raise SystemExit("Unexpected ggml CPU quantization source")

text = src.read_text()
guard = "defined(__ARM_NEON) && defined(__arm__) && !defined(__aarch64__)"
first = text.index("void ggml_vec_dot_q5_0_q8_0(")
text = text[:first] + f"#if {guard}\n#include \"k_quants.h\"\n#endif\n\n" + text[first:]
for bits in (4, 6):
    fn = text.index(f"void ggml_vec_dot_q{bits}_K_q8_K(")
    start = text.index("#ifdef __ARM_NEON", fn)
    text = text[:start] + f"#if {guard}\n    *s = a9_q{bits}_k(nb, x, y);\n#elif defined(__ARM_NEON)" + text[start + len("#ifdef __ARM_NEON"):]

fn = text.index("void ggml_vec_dot_q5_0_q8_0(")
neon = text.index("#if defined(__ARM_NEON)", fn)
text = text[:neon] + f"""#if {guard}
    float32x4_t sumv0 = vdupq_n_f32(0.0f);
    float32x4_t sumv1 = vdupq_n_f32(0.0f);
    for (; ib + 1 < nb; ib += 2) {{
        const block_q5_0 * restrict x0 = &x[ib];
        const block_q5_0 * restrict x1 = &x[ib + 1];
        const block_q8_0 * restrict y0 = &y[ib];
        const block_q8_0 * restrict y1 = &y[ib + 1];
        sumv0 = vmlaq_n_f32(sumv0, vcvtq_f32_s32(a9_q5_block(x0, y0)),
                           GGML_FP16_TO_FP32(x0->d) * GGML_FP16_TO_FP32(y0->d));
        sumv1 = vmlaq_n_f32(sumv1, vcvtq_f32_s32(a9_q5_block(x1, y1)),
                           GGML_FP16_TO_FP32(x1->d) * GGML_FP16_TO_FP32(y1->d));
    }}
    sumf = vaddvq_f32(sumv0) + vaddvq_f32(sumv1);
#elif defined(__ARM_NEON)""" + text[neon + len("#if defined(__ARM_NEON)"):]

patched = here / src.name
patched.write_text(text)
flags = (build / "ggml/src/CMakeFiles/ggml-cpu.dir/flags.make").read_text()
options = []
for key in ("C_DEFINES", "C_INCLUDES", "C_FLAGS"):
    options.extend(shlex.split(re.search(rf"^{key} = (.*)$", flags, re.M)[1]))
obj = here / "ggml-cpu-quants.c.o"
subprocess.run(["cc", *options, "-c", patched, "-o", obj], check=True)
archive = here / "libggml-cpu.a"
shutil.copyfile(resident / archive.name, archive)
subprocess.run(["ar", "r", archive, obj], check=True)
members = subprocess.check_output(["ar", "t", archive], text=True).splitlines()
if members.count(obj.name) != 1:
    raise SystemExit("GGML archive member replacement failed")
link_dir = build / "examples/main"
link = shlex.split((link_dir / "CMakeFiles/llama-cli.dir/link.txt").read_text())
link[link.index("-o")+1] = str(here / "llama-cli-a9")
link[link.index("../../ggml/src/libggml-cpu.a")] = str(archive)
subprocess.run(link, cwd=link_dir, check=True)
