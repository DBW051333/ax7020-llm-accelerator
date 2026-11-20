"""Restore the usual temporary SSH address after a board reboot."""
import argparse
import ipaddress
import os
import re
import time

import serial

parser = argparse.ArgumentParser()
parser.add_argument('--port', default='COM11')
parser.add_argument('--address', required=True, type=ipaddress.IPv4Interface)
args = parser.parse_args()
password = os.environ['AX7020_PASSWORD'].encode()+b'\n'
shell = rb'xilinx@pynq:[^\r\n]*\$ $'
console = serial.Serial(port=None, baudrate=115200, timeout=.1)
console.port = args.port
console.rts = console.dtr = False


def wait(*markers):
    buf = bytearray()
    end = time.monotonic()+12
    while time.monotonic()<end:
        buf.extend(console.read(console.in_waiting or 1))
        for marker in markers:
            if re.search(marker,buf): return marker
    raise TimeoutError(f'UART did not reach {markers!r}')


console.open()
try:
    console.write(b'\n')
    if wait(rb'pynq login: *$',shell)!=shell:
        console.write(b'xilinx\n')
        wait(rb'Password: *$')
        console.write(password)
        wait(shell)
    prompt = rb'[\r\n]LOCAL_SUDO:$'
    console.write(f"sudo -p 'LOCAL_SUDO:' ip addr replace {args.address} dev eth0 label eth0:ssh\n".encode())
    if wait(prompt,shell)==prompt:
        console.write(password)
        wait(shell)
    console.write(b'ip -br addr show eth0\n')
    wait(re.escape(str(args.address).encode()))
    print(f'UART verified eth0 address {args.address}')
finally:
    console.close()
