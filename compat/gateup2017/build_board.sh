#!/bin/bash
set -euo pipefail
cd /home/xilinx/ax7020-gateup2017
old=/home/xilinx/ax7020-validation2017
python3 - <<'PY'
from pathlib import Path
import hashlib,json,shutil
base=Path('/home/xilinx/ax7020-validation2017/llama.cpp')
backup=Path('baseline-source');backup.mkdir(exist_ok=True)
for rel,sha in json.loads(Path('software/original-hashes.json').read_text()).items():
    p=base/rel
    if hashlib.sha256(p.read_bytes()).hexdigest()!=sha: raise SystemExit('Source differs from pinned baseline: '+rel)
    dst=backup/rel
    if dst.exists():
        if hashlib.sha256(dst.read_bytes()).hexdigest()!=sha: raise SystemExit('Backup differs: '+rel)
    else:
        dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dst)
for rel in json.loads(Path('software/original-hashes.json').read_text()):
    shutil.copyfile(Path('software')/rel,base/rel)
PY
restore() {
python3 - <<'PY'
from pathlib import Path
import json,shutil
base=Path('/home/xilinx/ax7020-validation2017/llama.cpp')
for rel in json.loads(Path('software/original-hashes.json').read_text()):
    shutil.copy2(Path('baseline-source')/rel,base/rel)
print('BASELINE-SOURCE-RESTORED')
PY
}
trap restore EXIT
mkdir -p bin logs
cmake -S "$old/llama.cpp" -B "$old/llama-build" \
 -DGGML_GATEUP=ON -DGGML_GATEUP_DIR="$PWD/board"
cmake --build "$old/llama-build" --target llama-cli -j 2
cp "$old/llama-build/bin/llama-cli" bin/llama-cli-gateup
gcc -O2 -mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard \
 -o bin/test_gateup board/test_gateup.c board/gateup_runtime.c -Iboard -ldl -lm -lpthread
sha256sum bin/llama-cli-gateup bin/test_gateup "$old/bin/llama-cli-blite"
echo GATEUP-SOFTWARE-BUILD-PASS
