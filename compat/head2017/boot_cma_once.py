"""AX7020 serial-assisted, one-boot CMA experiment. No U-Boot saveenv."""
from pathlib import Path
import argparse
import re
import subprocess
import sys
import time

import serial

args_parser = argparse.ArgumentParser()
args_parser.add_argument('--port', default='COM11')
args_parser.add_argument('--host', required=True)
args_parser.add_argument('--mib', type=int, choices=(128, 384), required=True)
args_parser.add_argument('--verify-installed', action='store_true',
                         help='Let the boot script import uEnv.txt and verify CMA on the console')
args_parser.add_argument('--log', type=Path, required=True)
args = args_parser.parse_args()
root = Path(__file__).resolve().parents[2]
prompt = re.compile(rb'(?:^|\n)(?:Zynq|ZynqMP|U-Boot|=>)[>#]? ?$', re.I)
console = serial.Serial(port=None, baudrate=115200, timeout=.05)
console.dtr = console.rts = False
console.port = args.port


def until(log, pattern, seconds, interrupt=False):
    buf = bytearray()
    end = time.monotonic()+seconds
    interrupted = False
    while time.monotonic() < end:
        data = console.read(console.in_waiting or 1)
        if not data:
            continue
        log.write(data)
        log.flush()
        buf.extend(data)
        if interrupt and not interrupted and b'Hit any key' in buf:
            console.write(b'\r')
            interrupted = True
        if pattern.search(buf):
            return bytes(buf)
    raise TimeoutError(f'serial marker timed out: {pattern.pattern!r}; see {args.log}')


console.open()
try:
    with args.log.open('wb') as log:
        ssh = [sys.executable, str(root/'tools/boardctl.py'), '--host', args.host, 'run']
        current = subprocess.check_output(ssh+['--command','cat /proc/cmdline']).splitlines()[0]
        if b'root=/dev/mmcblk0p2' not in current:
            raise SystemExit('Unexpected root device; did not reboot')
        console.reset_input_buffer()
        with subprocess.Popen(ssh+['--sudo', '--command',
                               'sync; systemctl reboot'], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL) as reboot:
            if args.verify_installed:
                output=until(log,re.compile(rb'login:|xilinx@pynq'), 150)
                if f'cma: Reserved {args.mib} MiB'.encode() not in output:
                    raise SystemExit('Linux booted without requested CMA; see serial log')
                print(f'Linux booted with persisted {args.mib} MiB CMA',flush=True)
                raise SystemExit(0)
            until(log,prompt,65,interrupt=True)
        console.write(b'printenv bootargs\r')
        output = until(log, prompt, 5)
        setting = re.search(rb'\nbootargs=([^\r\n]+)', output)
        inherited = setting[1] if setting else current
        if b'root=/dev/mmcblk0p2' not in inherited:
            console.write(b'run bootcmd\r')
            raise SystemExit('Unexpected U-Boot bootargs; resumed the default boot')
        bootargs = re.sub(rb'(?:^| )cma=[^ ]+', b'', inherited)
        if any(c in bootargs for c in (b"'", b'\\', b';')):
            console.write(b'run bootcmd\r')
            raise SystemExit('Unexpected U-Boot quoting; resumed the default boot')
        console.write(b"setenv bootargs '"+bootargs+f" cma={args.mib}M'\r".encode())
        until(log,prompt,5)
        console.write(b'run bootcmd\r')
        print(f'Booting experiment with cma={args.mib}M without saving U-Boot environment',flush=True)
        until(log,re.compile(rb'login:|xilinx@pynq'),110)
        print('Linux login prompt reached',flush=True)
finally:
    console.close()
