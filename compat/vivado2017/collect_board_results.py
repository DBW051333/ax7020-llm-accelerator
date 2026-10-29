"""Collect board evidence; refuse to report model success without real PL calls."""
from pathlib import Path
import hashlib
import json
import re

root = Path(__file__).resolve().parents[2]
directory = root/'build/board-validation2017'
def read(name):
    return (directory/name).read_text(encoding='utf8',errors='replace')
loaded = json.loads(read('loaded-overlay.json'))
if loaded['status']!='OVERLAY-LOADED' or abs(loaded['fclk0_mhz']-83.333333)>.05:
    raise SystemExit('Overlay load/frequency evidence missing')
dma = []
for line in read('dma-validation.log').splitlines():
    if line.startswith('PARALLEL-PASS '):
        dma.append(dict(re.findall(r'(\w+)=([^ ]+)',line)))
if len(dma)!=38 or len([r for r in dma if r.get('check')=='bit-exact'])!=37:
    raise SystemExit('Expected full DMA sweep and stress evidence')
matrix = re.search(r'REAL-MATVEC-PASS rows=896 k=4864 tests=5 worst_relative_L2=([\d.e+-]+)',read('real-matvec.log'))
if not matrix or float(matrix.group(1))>1e-4:
    raise SystemExit('Real matrix evidence failed')
model_console=read('model-test-console.log')
cpu,pl = [(directory/f'model-{mode}.stdout').read_bytes() for mode in ['cpu','pl']]
repeat=(directory/'model-cpu-repeat.stdout').read_bytes()
text_parity=cpu==pl and repeat==pl
cpu_stable=cpu==repeat
if not cpu_stable:
    raise SystemExit('CPU repetitions are unstable; investigate before classifying PL parity')
if text_parity and 'MODEL-TEST-PASS' not in model_console:
    raise SystemExit('Model test script did not finish successfully')
if not text_parity and 'differ: byte' not in model_console:
    raise SystemExit('Missing expected text-parity failure evidence')
verify24=read('model-verify24.stderr')
verify24_calls=re.search(r'BLITE-STATS calls=(\d+)',verify24)
if 'VERIFY24-NUMERIC-PASS' not in read('verify24-console.log') or not verify24_calls or int(verify24_calls.group(1))==0:
    raise SystemExit('Full-length numeric verification incomplete')
pl_repeat_stable=(directory/'model-verify24.stdout').read_bytes()==pl
verify = read('model-verify.stderr')
relative = re.findall(r'BLITE-VERIFY (\S+) relative_L2=([\d.e+-]+)',verify)
calls = re.search(r'BLITE-STATS calls=(\d+)',verify)
if len(relative)!=12 or not calls or int(calls.group(1))==0:
    raise SystemExit('Missing per-layer numeric verification or hardware calls')
def timing(mode):
    text=read(f'model-{mode}.stderr')
    match=re.search(r'(?<!prompt )eval time\s*=\s*([\d.]+) ms\s*/\s*(\d+) runs',text)
    if not match:
        raise SystemExit(f'Missing decode timing: {mode}')
    milliseconds,runs=float(match.group(1)),int(match.group(2))
    record={'decode_ms':milliseconds,'decode_runs':runs,'tokens_per_second':runs*1000/milliseconds}
    hardware=re.search(r'BLITE-STATS calls=(\d+).*?cache_misses=(\d+).*?dma_ms=([\d.]+)',text)
    if hardware:
        record.update({'hardware_calls':int(hardware.group(1)),'cache_misses':int(hardware.group(2)),
                       'dma_ms':float(hardware.group(3))})
    return record
measurements={mode:timing(mode) for mode in ['cpu','pl','cpu-repeat']}
if measurements['pl'].get('hardware_calls',0)==0:
    raise SystemExit('Performance run did not use the FPGA')
if len({item['decode_runs'] for item in measurements.values()})!=1:
    raise SystemExit('CPU and PL decode lengths differ')
result={'status':'BOARD-AND-MODEL-PASS' if text_parity else 'BOARD-PASS-MODEL-TEXT-PARITY-FAIL',
        'client_date':'2026-10-28','timezone':'Asia/Shanghai',
        'overlay':loaded,'dma_cases':dma,'real_matrix_worst_relative_L2':float(matrix.group(1)),
        'model_verify_hardware_calls':int(calls.group(1)),
        'model_verify_printed_layers':[{'name':name,'relative_L2':float(value)} for name,value in relative],
        'measurements':measurements,'generated_output_byte_identical':text_parity,
        'cpu_repeat_byte_identical':cpu_stable,'pl_repeat_with_verification_byte_identical':pl_repeat_stable,
        'full_length_verify_hardware_calls':int(verify24_calls.group(1)),
        'quality_preserving_speedup_accepted':text_parity,
        'decode_rate_ratio':measurements['pl']['tokens_per_second']/measurements['cpu']['tokens_per_second'],
        'decode_rate_ratio_vs_cpu_repeat':measurements['pl']['tokens_per_second']/measurements['cpu-repeat']['tokens_per_second'],
        'first_differing_byte_1based':next((i+1 for i,(a,b) in enumerate(zip(cpu,pl)) if a!=b),None),
        'native_binary_sha256':hashlib.sha256((directory/'bin/llama-cli-blite').read_bytes()).hexdigest(),
        'source_revision':'dafae66cc242eb766797194d3c85c5e502625623',
        'model_sha256':'23c36f3a641c0062f5f60b1b98c652233a40adcc2c9f6c24df87d2e2b996248c',
        'output_sha256':hashlib.sha256(cpu).hexdigest(),
        'files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.iterdir()
                 if p.is_file() and p.suffix in ['.log','.stdout','.stderr','.json'] and p.name!='board-result.json'}}
(directory/'board-result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf8')
print(json.dumps({'status':result['status'],'measurements':measurements,
                  'quality_preserving_speedup_accepted':text_parity},indent=2))
