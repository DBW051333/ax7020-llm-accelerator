"""Verify and restore the immutable delivered snapshot under accel/ (no overwrite)."""
from pathlib import Path
import hashlib
import io
import tarfile

root = Path(__file__).resolve().parents[1]
for line in (root / 'source/PARTS.sha256').read_text().splitlines():
    expected, name = line.split(maxsplit=1)
    if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
        raise SystemExit(f'Part checksum failed: {name}')
raw = b''.join(p.read_bytes() for p in sorted((root / 'source').glob('*.part-*')))
expected = (root / 'source/SHA256SUMS').read_text().split()[0]
if hashlib.sha256(raw).hexdigest() != expected:
    raise SystemExit('Archive checksum failed')
destination = root / 'accel'
with tarfile.open(fileobj=io.BytesIO(raw), mode='r:xz') as archive:
    files = []
    for member in archive.getmembers():
        parts = member.name.split('/')
        if parts[0] != 'ax7020-llm-accelerator' or not (member.isfile() or member.isdir()):
            raise SystemExit(f'Unsupported archive member: {member.name}')
        target = destination.joinpath(*parts[1:])
        if not target.resolve().is_relative_to(destination.resolve()):
            raise SystemExit(f'Unsafe archive member: {member.name}')
        if member.isfile():
            data = archive.extractfile(member).read()
            if target.exists() and target.read_bytes() != data:
                raise SystemExit(f'Existing source differs; preserve and inspect: {target}')
            files.append((target, data))
    for target, data in files:
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            target.write_bytes(data)
print(f'PASS: {len(files)} source files verified/restored in {destination}')
