#!/usr/bin/python3
"""A service-manager test double that runs the real exporter as its service user.

The container has no systemd PID 1. Unit syntax is checked separately with the
real systemd-analyze; this double covers lifecycle, readiness and rollback only.
"""
import json
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys
import time

root = Path('/tmp/service-manager-test')
root.mkdir(exist_ok=True)
state_file = root / 'state.json'
state = json.loads(state_file.read_text()) if state_file.exists() else {'pid': None, 'enabled': False}
command = sys.argv[1]

def active():
    pid = state['pid']
    if not pid:
        return False
    try:
        return Path(f'/proc/{pid}/stat').read_text().split()[2] != 'Z'
    except FileNotFoundError:
        return False

def stop():
    if active():
        os.kill(state['pid'], signal.SIGTERM)
        for _ in range(100):
            if not active():
                break
            time.sleep(.02)
        if active():
            os.kill(state['pid'], signal.SIGKILL)
    state['pid'] = None

def save():
    state_file.write_text(json.dumps(state))

if command == 'show':
    if '--property=User' in sys.argv:
        unit = Path('/etc/systemd/system/exporterd.service').read_text()
        user = next(line.split('=', 1)[1] for line in unit.splitlines() if line.startswith('User='))
        print(user)
    else:
        print('255')
elif command == 'is-active':
    sys.exit(0 if active() else 3)
elif command == 'is-enabled':
    sys.exit(0 if state['enabled'] else 1)
elif command == 'daemon-reload':
    pass
elif command == 'enable':
    state['enabled'] = True
elif command == 'disable':
    state['enabled'] = False
elif command == 'stop':
    stop()
elif command in ('restart', 'start'):
    stop()
    failure = root / 'fail-next-start'
    if failure.exists():
        failure.unlink()
        save()
        sys.exit(1)
    config = Path('/etc/default/exporterd').read_text()
    address = next(line.split('=', 1)[1] for line in config.splitlines() if line.startswith('LISTEN_ADDRESS='))
    account = pwd.getpwnam('node_exporter')
    with (root / 'exporter.log').open('ab') as log:
        process = subprocess.Popen(['/usr/local/bin/node_exporter', f'--web.listen-address={address}'],
                                   user=account.pw_uid, group=account.pw_gid, extra_groups=[],
                                   stdout=log, stderr=log, start_new_session=True)
    state['pid'] = process.pid
else:
    raise SystemExit(f'Unexpected systemctl operation: {sys.argv[1:]}')
save()
