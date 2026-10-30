"""SSH/SFTP helper. Credentials and expected host key come from process env only."""
import argparse
import base64
import hashlib
import os
from pathlib import Path, PurePosixPath
import socket
import sys
import time
import warnings

warnings.filterwarnings('ignore', category=DeprecationWarning)
warnings.filterwarnings('ignore', message='Blowfish has been deprecated')
import paramiko

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--user', default='xilinx')
sub = parser.add_subparsers(dest='action', required=True)
run = sub.add_parser('run')
source = run.add_mutually_exclusive_group(required=True)
source.add_argument('--script')
source.add_argument('--command')
run.add_argument('--sudo', action='store_true')
run.add_argument('--timeout', type=int, default=60)
run.add_argument('--log')
put = sub.add_parser('put')
put.add_argument('local')
put.add_argument('remote')
get = sub.add_parser('get')
get.add_argument('remote')
get.add_argument('local')
args = parser.parse_args()
password = os.environ['AX7020_PASSWORD']
expected = os.environ['AX7020_SSH_FINGERPRINT'].removeprefix('SHA256:')
transport = paramiko.Transport(socket.create_connection((args.host,22), timeout=8))
try:
    transport.get_security_options().key_types = ('ssh-ed25519',)
    transport.start_client(timeout=10)
    actual = base64.b64encode(hashlib.sha256(transport.get_remote_server_key().asbytes()).digest()).decode().rstrip('=')
    if actual != expected:
        raise SystemExit('SSH host key differs from the trusted board identity')
    transport.auth_password(args.user,password)
    if args.action in ('put','get'):
        with paramiko.SFTPClient.from_transport(transport) as sftp:
            if args.action == 'put':
                parent = PurePosixPath(args.remote).parent
                for item in reversed([parent,*parent.parents]):
                    if str(item) in ('.','/'):
                        continue
                    try:
                        sftp.stat(str(item))
                    except FileNotFoundError:
                        sftp.mkdir(str(item))
                sftp.put(args.local,args.remote)
                print(f'UPLOADED {Path(args.local).name}: {Path(args.local).stat().st_size} bytes')
            else:
                local = Path(args.local)
                local.parent.mkdir(parents=True,exist_ok=True)
                sftp.get(args.remote,str(local))
                print(f'DOWNLOADED {local.name}: {local.stat().st_size} bytes')
    else:
        script = Path(args.script).read_text(encoding='utf8') if args.script else args.command
        channel = transport.open_session(timeout=10)
        # timeout kills the remote process group if this client is interrupted.
        command = f'timeout --signal=TERM --kill-after=5 {args.timeout} /bin/bash -s'
        if args.sudo:
            command = 'sudo -k -S -p "" -- '+command
        channel.exec_command(command)
        payload = ((password+'\n') if args.sudo else '')+script.rstrip()+'\n'
        channel.sendall(payload.encode())
        channel.shutdown_write()
        output = bytearray()
        end = time.monotonic()+args.timeout+20
        while time.monotonic()<end:
            for ready, receive in [(channel.recv_ready,channel.recv),(channel.recv_stderr_ready,channel.recv_stderr)]:
                if ready():
                    block = receive(65536)
                    output.extend(block)
                    sys.stdout.buffer.write(block)
                    sys.stdout.buffer.flush()
            if channel.exit_status_ready() and not channel.recv_ready() and not channel.recv_stderr_ready():
                break
            time.sleep(.05)
        else:
            raise SystemExit('SSH timeout; inspect remote timeout/lock before further hardware access')
        if args.log:
            path = Path(args.log)
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(output)
        code = channel.recv_exit_status()
        print(f'\nREMOTE_EXIT={code}',flush=True)
        sys.exit(code)
finally:
    transport.close()
