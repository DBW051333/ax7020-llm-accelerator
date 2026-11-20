"""Rebuild one runtime object and relink the accepted combined application."""
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

here = Path(__file__).resolve().parent
base = Path('/home/xilinx/ax7020-decode2017')
build = base/'llama-build'
runtime = (base/'board/gateup_runtime.c').read_text()
if sys.argv[1:]:
    raise SystemExit('usage: build_resident.py')
source = here/'gateup_runtime.c'
needle = 'static void head_cleanup(void);'
assert runtime.count(needle) == 1
runtime = runtime.replace(needle, needle+'\nstatic void resident_cleanup(void);')
needle = ' head_cleanup();'
assert runtime.count(needle) == 1
runtime = runtime.replace(needle, ' resident_cleanup();\n'+needle)
needle = 'int gateup_fused('
assert runtime.count(needle) == 1
runtime = runtime.replace(needle,'static int staged_gateup_fused(')+'\n#include "resident_gateup.inc"\n'
source.write_text(runtime)
for name in ('gateup_runtime.h','head_runtime.inc','head_cpu.inc','test_gateup.c'):
    shutil.copyfile(base/'board'/name, here/name)

def run(command, **kwargs):
    subprocess.run([str(s) for s in command], check=True, **kwargs)

flags = (build/'ggml/src/CMakeFiles/ggml-cpu.dir/flags.make').read_text()
cc = ['cc']
for key in ('C_DEFINES','C_INCLUDES','C_FLAGS'):
    cc += shlex.split(re.search(rf'^{key} = (.*)$', flags, re.M)[1])
obj = here/'gateup_runtime.c.o'
run([*cc, '-c', source, '-o', obj])
archive = here/'libggml-cpu.a'
shutil.copyfile(build/'ggml/src/libggml-cpu.a',archive)
run(['ar','r',archive,obj])
members = subprocess.check_output(['ar','t',archive], text=True).splitlines()
assert members.count(obj.name) == 1
link_dir = build/'examples/main'
link = shlex.split((link_dir/'CMakeFiles/llama-cli.dir/link.txt').read_text())
link[link.index('-o')+1] = here/'llama-cli-resident'
link[link.index('../../ggml/src/libggml-cpu.a')] = archive
run(link,cwd=link_dir)
run([*cc, here/'test_gateup.c', obj, '-o', here/'test_gateup_resident','-ldl','-lm','-lpthread'])
run(['sha256sum',here/'llama-cli-resident',here/'test_gateup_resident'])
