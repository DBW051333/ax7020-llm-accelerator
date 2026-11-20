#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
base=/home/xilinx/ax7020-validation2017
v5=/home/xilinx/ax7020-gateup2017
export HEAD_BASE="$base" HEAD_V5="$v5"
if [[ ${1:-} != --resume ]]; then
python3 - <<'PY'
import hashlib, json, os, shutil
from pathlib import Path
base=Path(os.environ['HEAD_BASE'])/'llama.cpp'
v5=Path(os.environ['HEAD_V5'])
src=Path('llama.cpp')
if src.exists(): raise SystemExit('use a fresh deployment folder for source generation')
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
assert sha(v5/'software/src/llama.cpp') == '89f116ea9aca502e52dea6516ded170d681162a9f9a70323784496ba80af7283'
assert sha(v5/'board/gateup_runtime.c') == '9cf5a14bdc7e70f46c45ae9f326027c50648301b81f18df72ad81cc89c855807'
manifest=json.loads((v5/'software/original-hashes.json').read_text())
for name,digest in manifest.items(): assert sha(base/name)==digest, name
shutil.copytree(base,src,ignore=shutil.ignore_patterns('.git','build','__pycache__'))
for path in manifest:
    shutil.copyfile(v5/'software'/path,src/path)
board=Path('board'); board.mkdir(exist_ok=True)
for name in ('gateup_runtime.c','gateup_runtime.h','test_gateup.c'):
    shutil.copyfile(v5/'board'/name,board/name)
for name in ('head_cpu.inc','head_runtime.inc'):
    shutil.copyfile(name,board/name)
file=board/'gateup_runtime.h'; text=file.read_text()
needle='int gateup_enabled(void);'
assert text.count(needle)==1
file.write_text(text.replace(needle,needle+'\nint head_enabled(void);\nint head_apply(const void *,const void *,float *);'))
file=board/'gateup_runtime.c'; text=file.read_text()
needle='static void cleanup(void){'
assert text.count(needle)==1
text=text.replace(needle,'static void head_cleanup(void);\n'+needle)
needle=' for(int j=0;j<32;j++){free(cache[j].data);'
assert text.count(needle)==1
file.write_text(text.replace(needle,' head_cleanup();\n'+needle)+'\n#include "head_runtime.inc"\n')
file=src/'src/llama.cpp'; text=file.read_text()
needle='static struct ggml_tensor * llm_build_ffn(\n'
assert text.count(needle)==1
text=text.replace(needle,Path('head_callback.inc').read_text()+'\n'+needle)
a=text.index('    struct ggml_cgraph * build_qwen2() {')
b=text.index('\n    struct ggml_cgraph *',a+10)
section=text[a:b]; needle='        cur = llm_build_lora_mm(lctx, ctx0, model.output, cur);'
assert section.count(needle)==1
section=section.replace(needle,'''#ifdef GGML_USE_GATEUP
        if (head_enabled() && lctx.lora_adapters.empty() &&
                cur->type==GGML_TYPE_F32 && ggml_is_contiguous(cur) &&
                cur->ne[0]==896 && cur->ne[1]==1 && cur->ne[2]==1 && cur->ne[3]==1 &&
                model.output->type==GGML_TYPE_Q8_0 && ggml_is_contiguous(model.output) &&
                model.output->ne[0]==896 && model.output->ne[1]==151936) {
            cur=ggml_map_custom3_shape(ctx0,cur,model.output,cur,head_compute,1,nullptr,151936,1);
        } else
#endif
''' + needle)
file.write_text(text[:a]+section+text[b:])
PY
fi
flags='-mcpu=cortex-a9 -mfp16-format=ieee -mfpu=neon-vfpv3 -mfloat-abi=hard'
cmake -S llama.cpp -B llama-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_OPENMP=OFF -DGGML_LLAMAFILE=OFF -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DGGML_BLITE=ON -DGGML_BLITE_DIR="$base/board" \
  -DGGML_GATEUP=ON -DGGML_GATEUP_DIR="$PWD/board" -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags"
cmake --build llama-build --target llama-cli -j 2
mkdir -p bin
cp llama-build/bin/llama-cli bin/llama-cli-decode
gcc -O2 -mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard \
  -o bin/test_gateup board/test_gateup.c board/gateup_runtime.c -Iboard -ldl -lm -lpthread
sha256sum bin/llama-cli-decode bin/test_gateup
