#!/usr/bin/env python3
"""Fixed-action host supervisor. No Docker socket or host shell in the web app."""
import argparse
import fcntl
import json
from pathlib import Path
import subprocess
import time
import urllib.request


class Supervisor:
    def __init__(self, stack):
        self.stack = Path(stack).resolve()
        self.compose = ['docker','compose','--project-directory',str(self.stack),'-f',str(self.stack/'compose.yml'),'--env-file',str(self.stack/'.env')]
        self.env = {}
        for line in (self.stack/'.env').read_text().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                key,value = line.split('=',1)
                self.env[key.strip()] = value.strip().strip('"').strip("'")

    def run(self, arguments):
        result = subprocess.run(self.compose + arguments, cwd=self.stack, capture_output=True, text=True, timeout=150, check=False)
        if result.returncode:
            raise RuntimeError('Container step failed; no activation performed by this step')
        return result.stdout

    def worker(self, command):
        # One-shot containers work even after a crash left the services stopped.
        output = self.run(['run','--rm','--no-deps','-T','site-agent','/app/.venv/bin/python','-m','app.services.cloud.replacement',command])
        return json.loads(output.strip().splitlines()[-1])

    def healthy(self, held):
        def address(prefix, default_port, path):
            host = self.env.get(prefix + '_BIND_HOST','127.0.0.1')
            if host in {'','0.0.0.0'}:
                host = '127.0.0.1'
            return 'http://' + host + ':' + self.env.get(prefix+'_HOST_PORT',default_port) + path
        urls = [address('SITE_AGENT','8000','/recovery/ready'), address('GATEWAYD','8080','/readyz')]
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                for url in urls:
                    with urllib.request.urlopen(url, timeout=3) as response:
                        data = json.load(response)
                    if not data.get('ok') or bool(data.get('commissioning_hold',False)) != held:
                        raise ValueError('Readiness does not match commissioning phase')
                return
            except (OSError, ValueError):
                time.sleep(2)
        raise RuntimeError('Services not ready; commissioning state preserved for retry')

    def tick(self):
        # Installed appliances do not need a container launched every 30s.
        storage = Path(self.env.get('IPC_STORAGE_DIR', '/opt/site-agent/storage'))
        local_marker = storage / 'ipc/replacement.json'
        local_identity = storage / 'ipc/identity.json'
        if local_marker.exists():
            persisted = json.loads(local_marker.read_text())
            if persisted.get('phase') == 'active' and persisted.get('finished'):
                return
        elif local_identity.exists() and json.loads(local_identity.read_text()).get('ipc_id'):
            return
        info = self.worker('status')
        phase = info['phase']
        if phase == 'idle':
            if info['paired']:
                return  # Existing installations retain autonomous behavior.
            phase = self.worker('stage')['phase']
        if phase == 'staged':
            self.run(['stop','site-agent','gatewayd'])
            phase = self.worker('apply')['phase']
        if phase == 'restored':
            self.run(['up','-d','gatewayd','site-agent'])
            self.healthy(held=True)
            phase = self.worker('activate')['phase']
        if phase == 'activated':
            self.worker('release')
            phase = 'active'
        if phase == 'active' and not info.get('finished'):
            # Idempotent after a crash anywhere between release/start/finish.
            if not info.get('started'):
                self.run(['up','-d','gatewayd','site-agent'])
                self.run(['restart','gatewayd','site-agent'])
                self.healthy(held=False)
                self.worker('started')
            self.worker('finish')
        print('Replacement supervisor: ' + phase)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stack', default='/opt/ipc-stack')
    args = parser.parse_args()
    with open('/run/lock/ipc-replacement.lock','w') as lock:
        try:
            fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        Supervisor(args.stack).tick()


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        raise SystemExit('Replacement supervisor paused safely: ' + type(exc).__name__) from None
