"""Relink the A9 NEON application with the Para-MAC Down runtime."""
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

here = Path(__file__).resolve().parent
base = Path("/home/xilinx/ax7020-decode2017")
a9 = Path("/home/xilinx/ax7020-a9-decode")
build = base / "llama-build"


def edit(s, old, new):
    if s.count(old) != 1:
        raise ValueError(f"Unexpected pinned source around {old!r}")
    return s.replace(old, new)


def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def options(target, cc):
    flags = (build / target / "flags.make").read_text()
    return [part for what in ("DEFINES", "INCLUDES", "FLAGS")
            for part in shlex.split(re.search(rf"^{cc}_{what} = (.*)$", flags, re.M)[1])]


def replace_object(archive, source, obj):
    shutil.copyfile(source, archive)
    run(["ar", "r", archive, obj])
    members = subprocess.check_output(["ar", "t", archive], text=True).splitlines()
    if members.count(obj.name) != 1:
        raise ValueError("Archive object replacement failed")


def build_runtime():
    runtime = (base / "board/gateup_runtime.c").read_text()
    runtime = edit(runtime, 'open("/tmp/blite-perf.lock",O_CREAT|O_RDWR,0600)',
                   'open("/tmp/blite-perf.lock",O_RDWR)')
    runtime = edit(runtime, "static int allocate(struct bo *b,size_t bytes){",
                   "static int allocate_flags(struct bo *b,size_t bytes,unsigned flags){")
    runtime = edit(runtime, "alloc_bo(device,bytes,3,0)", "alloc_bo(device,bytes,3,flags)")
    runtime = edit(runtime, "static int reset(void){", """static int allocate(struct bo *b,size_t bytes){
 return allocate_flags(b,bytes,0);
}
static int reset(void){""")
    runtime = edit(runtime, "static void head_cleanup(void);", """static void head_cleanup(void);
static void resident_cleanup(void);
static void para_cleanup(void);""")
    runtime = edit(runtime, " head_cleanup();", " para_cleanup();\n resident_cleanup();\n head_cleanup();")
    runtime = edit(runtime, "int gateup_fused(", "static int staged_gateup_fused(")
    runtime += '\n#include "resident_gateup.inc"\n#include "para_runtime.inc"\n'
    for name in ("gateup_runtime.h", "head_runtime.inc", "head_cpu.inc"):
        shutil.copyfile(base/"board"/name, here/name)
    source = here / "gateup_runtime.c"
    obj = here / "gateup_runtime.c.o"
    source.write_text(runtime)
    run(["cc", *options("ggml/src/CMakeFiles/ggml-cpu.dir", "C"), "-c", source, "-o", obj])
    replace_object(here/"libggml-cpu.a", a9/"libggml-cpu.a", obj)


def build_graph():
    source = here / "llama.cpp"
    obj = here / "llama.cpp.o"
    raw = (base / "llama.cpp/src/llama.cpp").read_text()
    needle = "static struct ggml_tensor * llm_build_lora_mm(\n"
    raw = edit(raw, needle, (here/"para_graph.inc").read_text()+"\n"+needle)
    needle = "    struct ggml_tensor * res = ggml_mul_mat(ctx0, w, cur);"
    raw = edit(raw, needle, """#ifdef GGML_USE_GATEUP
    if (lctx.lora_adapters.empty() && para_shape(w, cur)) {
        return ggml_map_custom3_shape(ctx0, cur, w, cur, para_compute, 1, nullptr, 896, 1);
    }
#endif
"""+needle)
    source.write_text(raw)
    run(["c++", *options("src/CMakeFiles/llama.dir", "CXX"), "-c", source, "-o", obj])
    replace_object(here/"libllama.a", build/"src/libllama.a", obj)


def build_cli():
    source = here/"main.cpp"
    obj = here/"main.cpp.o"
    raw = (base/"llama.cpp/examples/main/main.cpp").read_text()
    needle = "                if (llama_decode(ctx, llama_batch_get_one(&embd[i], n_eval))) {"
    raw = edit(raw, needle, """                const bool para_timing = std::getenv("BLITE_PARA_TIMING") && n_eval == 1;
                const int64_t para_start = para_timing ? ggml_time_us() : 0;
"""+needle)
    needle = "                n_past += n_eval;"
    raw = edit(raw, needle, """                if (para_timing) {
                    std::fprintf(stderr, "PARA-STEP past=%d us=%lld\\n", n_past,
                                 static_cast<long long>(ggml_time_us()-para_start));
                }
"""+needle)
    source.write_text(raw)
    run(["c++", *options("examples/main/CMakeFiles/llama-cli.dir", "CXX"), "-c", source, "-o", obj])


def link():
    directory = build/"examples/main"
    cmd = shlex.split((directory/"CMakeFiles/llama-cli.dir/link.txt").read_text())
    cmd[cmd.index("-o")+1] = here/"llama-cli-para"
    cmd[cmd.index("../../ggml/src/libggml-cpu.a")] = here/"libggml-cpu.a"
    cmd[cmd.index("../../src/libllama.a")] = here/"libllama.a"
    cli_object = "CMakeFiles/llama-cli.dir/main.cpp.o"
    cmd[cmd.index(cli_object)] = here/"main.cpp.o"
    run(cmd, cwd=directory)


if __name__ == "__main__":
    stages = sys.argv[1:] or ["runtime", "graph", "cli", "link"]
    for stage in stages:
        {"runtime": build_runtime, "graph": build_graph, "cli": build_cli, "link": link}[stage]()
