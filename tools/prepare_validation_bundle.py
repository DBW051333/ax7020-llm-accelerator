"""Prepare pinned, reviewable board assets without storing login information."""
from pathlib import Path
import hashlib
import json
import posixpath
import subprocess
import tarfile
import urllib.request

root = Path(__file__).resolve().parents[1]
revision = 'dafae66cc242eb766797194d3c85c5e502625623'
expected = '933eccfb927b5e921ca23f18b2454583a6c6dcc89917fc07c0bb8f3dcffdb912'
archive = root/'build/downloads/llama-dafae66.tar.gz'
archive.parent.mkdir(parents=True,exist_ok=True)
if not archive.exists():
    temp = archive.with_suffix('.download')
    with urllib.request.urlopen(f'https://codeload.github.com/ggml-org/llama.cpp/tar.gz/{revision}',timeout=60) as response,temp.open('wb') as output:
        while block := response.read(1024*1024):
            output.write(block)
    if hashlib.sha256(temp.read_bytes()).hexdigest()!=expected:
        raise SystemExit('Upstream download checksum differs from the validated snapshot')
    temp.replace(archive)
if hashlib.sha256(archive.read_bytes()).hexdigest()!=expected:
    raise SystemExit('Cached upstream archive checksum failed')
source = root/f'build/upstream/llama.cpp-{revision}'
if not source.exists():
    with tarfile.open(archive) as upstream:
        for item in upstream.getmembers():
            target=root/'build/upstream'/item.name
            if not target.resolve().is_relative_to(source.resolve()):
                raise SystemExit(f'Unsafe source path: {item.name}')
            if item.issym() or item.islnk():
                link=posixpath.normpath(posixpath.join(posixpath.dirname(item.name),item.linkname) if item.issym() else item.linkname)
                if not link.startswith(f'llama.cpp-{revision}/'):
                    raise SystemExit(f'Unsafe source link: {item.name}')
            elif not (item.isfile() or item.isdir()):
                raise SystemExit(f'Unsupported member: {item.name}')
        for item in upstream.getmembers():
            target=root/'build/upstream'/item.name
            if item.isdir():
                target.mkdir(parents=True,exist_ok=True)
            else:
                target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes(upstream.extractfile(item).read())
patch = root/'accel/llama.cpp-integration.patch'
directory = source.relative_to(root).as_posix()
command = ['git','apply',f'--directory={directory}']
patched = subprocess.run(command+['--reverse','--check',str(patch)],cwd=root,capture_output=True).returncode==0
if not patched:
    subprocess.run(command+['--check',str(patch)],cwd=root,check=True)
    subprocess.run(command+[str(patch)],cwd=root,check=True)
for relative, marker in [('ggml/src/ggml-cpu/CMakeLists.txt','GGML_BLITE'),('ggml/src/ggml-cpu/ggml-cpu.c','blite_matvec')]:
    if marker not in (source/relative).read_text():
        raise SystemExit(f'Missing integration change: {relative}')
out=root/'build/board-validation2017'
out.mkdir(parents=True,exist_ok=True)
items=[]
for suffix in ['.bit','.hwh','.hdf']:
    path=root/f'build/vivado2017/quad-2017/blite_quad_2017{suffix}'
    items.append((path,'overlay/'+path.name))
for name in ['perf_parallel.c','perf_run.c','blite_runtime.c','blite_runtime.h','test_real_matvec.c']:
    items.append((root/'accel/board'/name,'board/'+name))
for directory, pattern in [('accel/board','perf_*.hex'),('accel/rtl','*.hex')]:
    items.extend((path,'vectors/'+path.name) for path in (root/directory).glob(pattern))
for name in ['load_overlay.py','build_board.sh','test_model.sh','verify_model24.sh']:
    items.append((root/'compat/vivado2017'/name,name))
def stable(info):
    info.mtime=0; info.uid=0; info.gid=0; info.uname=''; info.gname=''
    return info
with tarfile.open(out/'board-bundle.tar.gz','w:gz') as bundle:
    for path,name in items:
        bundle.add(path,arcname=name,filter=stable)
with tarfile.open(out/'llama-patched.tar.gz','w:gz') as bundle:
    bundle.add(source,arcname='llama.cpp',filter=stable)
manifest = {'upstream_revision':revision,'upstream_archive_sha256':expected,
            'patch_sha256':hashlib.sha256(patch.read_bytes()).hexdigest(),
            'assets':{name:hashlib.sha256(path.read_bytes()).hexdigest() for path,name in items},
            'bundles':{path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in out.glob('*.tar.gz')}}
(out/'bundle-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf8')
print(f'Prepared pinned board bundles in {out}')
