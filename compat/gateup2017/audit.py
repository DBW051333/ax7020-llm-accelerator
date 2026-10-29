"""Apply the baseline interface gates to the new four-lane topology."""
from pathlib import Path
import os
root=Path(__file__).resolve().parents[2]
for name in ['audit_netlist.py','audit_handoff.py']:
    code=(root/'compat/vivado2017'/name).read_text()
    code=code.replace('build/vivado2017/quad-2017','build/gateup2017/quad-2017')
    code=code.replace('build/gateup2017/quad-2017','build/gateup2017/'+os.environ.get('GATEUP_BUILD_TAG','quad-2017'))
    code=code.replace('blite_quad_2017','gateup_quad_2017').replace('blite_quad','gateup_quad')
    exec(compile(code,name,'exec'),{'__file__':__file__,'__name__':'__main__'})
