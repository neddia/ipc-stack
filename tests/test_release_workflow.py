"""Run deployment scripts against disposable files and fake host/Docker commands.

Only the root-user guard is removed from copied install/update scripts. No real
services, registry, host configuration, or production credentials are touched.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.stack = self.root / 'stack'
        self.stack.mkdir()
        for name in ('install.sh', 'prod-up.sh', 'update.sh', '.env.example',
                     'scripts/gen-ipc-secrets.sh', 'scripts/ensure-ipc-identity.py',
                     'scripts/release-registry.sh', 'scripts/storage-snapshot.py',
                     'scripts/install-enrollment.py', 'provision/hyperv/build-media.sh',
                     'provision/autoinstall/user-data', 'provision/autoinstall/meta-data'):
            target = self.stack / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
            if name in ('install.sh', 'update.sh'):
                text = target.read_text()
                start = text.index('if [ "${EUID:')
                end = text.index('\nfi\n', start) + len('\nfi\n')
                target.write_text(text[:start] + text[end:])
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands.jsonl'
        self.storage = self.root / 'storage'
        self.secrets = self.root / 'secrets'
        self.env_file = self.stack / '.env'
        self.env_file.write_text(
            'SITE_AGENT_IMAGE=example/site-agent\nSITE_AGENT_VERSION=v1\n'
            f'IPC_STORAGE_DIR={self.storage}\nIPC_SECRETS_DIR={self.secrets}\n'
            'HARDWARE_SERIAL=test-hardware\nSITE_AGENT_UID=\nSITE_AGENT_GID=\n'
            'OPTIMIZER_LICENSE_POLICY=disabled\n'
            'SKIP_HARDENING=1\nSKIP_TAILSCALE=1\nSKIP_IMAGE_PULL=1\n'
            'TAILSCALE_IP=100.64.0.1\nTAILSCALE_SSH_ONLY=0\n'
        )
        host = self.root / 'host-id'
        host.write_text('test-hardware')
        docker_config = self.root / 'docker-config'
        docker_config.mkdir()
        (docker_config / 'config.json').write_text('{"auths":{"ghcr.io":{}}}')
        # Intentionally do not inherit runtime configuration or credentials.
        self.env = {
            'PATH': str(self.bin) + os.pathsep + os.defpath,
            'HOME': str(self.root), 'DOCKER_CONFIG': str(docker_config),
            'IPC_HARDWARE_ID_FILE': str(host), 'TEST_COMMAND_LOG': str(self.log),
            'IPC_STORAGE_DIR': str(self.storage), 'IPC_SECRETS_DIR': str(self.secrets),
            'TEST_ROOT': str(self.root),
            'DOCKER_DAEMON_JSON': str(self.root / 'daemon.json'),
            'IPC_CONSOLE_ISSUE_FILE': str(self.root / 'issue.d/toops-ipc.issue'),
            'TAILSCALE_APPROVAL_POLL_SECONDS': '0',
        }
        self.executable(self.bin / 'chown', '#!/bin/sh\nexit 0\n')
        # Host commands record their arguments and otherwise succeed.
        for name in ('systemctl', 'agetty', 'tailscaled'):
            self.executable(self.bin / name, f'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_COMMAND_LOG'], 'a') as log:
    log.write(json.dumps({{'args': ['{name}', *sys.argv[1:]], 'version': None}}) + '\\n')
''')
        # Fake Tailscale walks through TEST_TAILSCALE_STATES, one per status call.
        self.executable(self.bin / 'tailscale', r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['TEST_COMMAND_LOG'], 'a') as log:
    log.write(json.dumps({'args': ['tailscale', *args], 'version': None}) + '\n')
if args[:1] == ['status']:
    counter = pathlib.Path(os.environ['TEST_ROOT']) / 'tailscale-count'
    n = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n + 1))
    states = os.environ.get('TEST_TAILSCALE_STATES', 'Running').split(',')
    print(json.dumps({'BackendState': states[min(n, len(states) - 1)]}))
elif args[:2] == ['ip', '-4']:
    print('100.64.0.9')
''')
        self.executable(self.bin / 'docker', r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
with open(os.environ['TEST_COMMAND_LOG'], 'a') as log:
    log.write(json.dumps({'args': args, 'version': os.environ.get('SITE_AGENT_VERSION')}) + '\n')
if args[:1] == ['images']:
    print('example/site-agent:v0\nexample/site-agent:v1\nexample/site-agent:v2')
if args[:2] == ['compose', 'pull'] and os.environ.get('TEST_PULL_FAIL'):
    sys.exit(1)
if args[:2] == ['image', 'inspect']:
    print(os.environ.get('TEST_REPO_DIGEST', ''))
if args == ['compose', 'up', '-d'] and os.environ.get('SITE_AGENT_VERSION') == 'v2' and os.environ.get('TEST_MIGRATE'):
    # The new release rewrites config the way a migration would.
    pathlib.Path(os.environ['IPC_STORAGE_DIR'], 'site-config.yml').write_text('migrated: true\n')
if args[:1] == ['run']:
    mounts = [args[i + 1].split(':') for i, arg in enumerate(args) if arg == '-v']
    stage = pathlib.Path(next(host for host, dest, *_ in mounts if dest == '/work/stage'))
    if '-extract' in args[-1]:
        (stage / 'grub.cfg').write_text('linux /casper/vmlinuz ---\n')
    else:
        capture = pathlib.Path(os.environ['TEST_ROOT']) / 'media-capture'
        shutil.copytree(stage, capture)
        output = pathlib.Path(next(host for host, dest, *_ in mounts if dest == '/out'))
        (output / 'ubuntu-ipc-autoinstall.iso').write_bytes(b'fake assembled media')
''')
        for name in ('sync-defaults.sh', 'bootstrap-influx.sh'):
            self.executable(self.stack / 'scripts' / name, '#!/bin/sh\nexit 0\n')
        self.executable(self.stack / 'scripts/check-health.sh', '''#!/usr/bin/env python3
import os, pathlib, sys
if '--capture-baseline' in sys.argv:
    sys.exit(0)
count = pathlib.Path(os.environ['TEST_ROOT']) / 'health-count'
n = int(count.read_text()) if count.exists() else 0
count.write_text(str(n + 1))
results = os.environ.get('TEST_HEALTH_RESULTS', '0').split(',')
sys.exit(int(results[min(n, len(results) - 1)]))
''')

    @staticmethod
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, name, *args, ok=True):
        result = subprocess.run(['bash', str(self.stack / name), *args], env=self.env,
                                cwd=self.stack, capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def make_identity(self):
        self.run_script('scripts/gen-ipc-secrets.sh')

    def test_install_generates_only_current_secrets_and_starts_stack(self):
        self.run_script('install.sh')
        names = {p.name for p in self.secrets.iterdir()}
        self.assertTrue({'ipc_ed25519', 'ipc_ed25519.pub', 'influx.admin.token'} <= names)
        self.assertNotIn('gatewayd.token', names)
        self.assertNotIn('GATEWAYD', self.env_file.read_text())
        self.assertIn(['compose', 'up', '-d'], [c['args'] for c in self.commands()])
        key = (self.secrets / 'ipc_ed25519').read_bytes()
        self.run_script('prod-up.sh', str(self.env_file))
        self.assertEqual(key, (self.secrets / 'ipc_ed25519').read_bytes())
        self.assertNotIn('gatewayd.token', {p.name for p in self.secrets.iterdir()})

    def test_update_keeps_current_and_previous_site_agent_images(self):
        self.make_identity()
        self.run_script('update.sh', 'v2')
        saved = self.env_file.read_text()
        self.assertIn('SITE_AGENT_VERSION=v2\n', saved)
        self.assertIn('SITE_AGENT_PREV_VERSION=v1\n', saved)
        self.assertNotIn('GATEWAYD', saved)
        removed = [c['args'][1] for c in self.commands() if c['args'][0] == 'rmi']
        self.assertEqual(removed, ['example/site-agent:v0'])

    def test_failed_update_rolls_back_and_does_not_prune_images(self):
        self.make_identity()
        self.env['TEST_HEALTH_RESULTS'] = '1,0'
        result = self.run_script('update.sh', 'v2', ok=False)
        self.assertIn('rollback to v1 healthy', result.stdout)
        self.assertIn('SITE_AGENT_VERSION=v1\n', self.env_file.read_text())
        starts = [c['version'] for c in self.commands() if c['args'] == ['compose', 'up', '-d']]
        self.assertEqual(starts, ['v2', 'v1'])
        self.assertFalse(any(c['args'][0] == 'rmi' for c in self.commands()))

    def seed_site_state(self):
        self.storage.mkdir(parents=True, exist_ok=True)
        (self.storage / 'site-config.yml').write_text('site: original\n')
        import sqlite3
        with sqlite3.connect(self.storage / 'ledger.sqlite3') as db:
            db.execute('CREATE TABLE t (v)')
            db.execute("INSERT INTO t VALUES ('before')")

    def test_update_snapshots_state_and_rollback_restores_it(self):
        self.make_identity()
        self.seed_site_state()
        self.env.update(TEST_HEALTH_RESULTS='1,0', TEST_MIGRATE='1')
        result = self.run_script('update.sh', 'v2', ok=False)
        self.assertIn('restoring site state', result.stdout)
        self.assertEqual((self.storage / 'site-config.yml').read_text(), 'site: original\n')
        args = [c['args'] for c in self.commands()]
        self.assertLess(args.index(['compose', 'stop', 'site-agent']), len(args) - 1 - args[::-1].index(['compose', 'up', '-d']))
        snapshots = list((self.storage / 'update-snapshots').iterdir())
        self.assertEqual(len(snapshots), 1)
        self.assertIn('v1-to-v2', snapshots[0].name)

    def test_successful_update_keeps_snapshot_and_new_state(self):
        self.make_identity()
        self.seed_site_state()
        self.env['TEST_MIGRATE'] = '1'
        self.run_script('update.sh', 'v2')
        self.assertEqual((self.storage / 'site-config.yml').read_text(), 'migrated: true\n')
        self.assertEqual(len(list((self.storage / 'update-snapshots').iterdir())), 1)

    def test_same_release_takes_no_snapshot(self):
        self.make_identity()
        self.seed_site_state()
        self.run_script('update.sh', 'v1')
        self.assertFalse((self.storage / 'update-snapshots').exists())

    def test_pull_failure_leaves_pin_unchanged(self):
        self.make_identity()
        self.env['TEST_PULL_FAIL'] = '1'
        self.run_script('update.sh', 'v2', ok=False)
        saved = self.env_file.read_text()
        self.assertIn('SITE_AGENT_VERSION=v1\n', saved)
        self.assertNotIn(['compose', 'up', '-d'], [c['args'] for c in self.commands()])

    def test_digest_mismatch_refuses_update(self):
        self.make_identity()
        good, bad = 'sha256:' + 'a' * 64, 'sha256:' + 'b' * 64
        self.env['TEST_REPO_DIGEST'] = f'example/site-agent@{bad}'
        result = self.run_script('update.sh', f'v2@{good}', ok=False)
        self.assertIn('does not match digest', result.stdout)
        self.assertIn('SITE_AGENT_VERSION=v1\n', self.env_file.read_text())
        self.assertNotIn(['compose', 'up', '-d'], [c['args'] for c in self.commands()])

    def test_matching_digest_is_pinned_and_rollback_restores_previous_digest(self):
        self.make_identity()
        first, second = 'sha256:' + 'a' * 64, 'sha256:' + 'b' * 64
        self.env['TEST_REPO_DIGEST'] = f'release-mirror:5000/example/site-agent@{first}'
        self.run_script('update.sh', f'v2@{first}')
        self.assertIn(f'SITE_AGENT_DIGEST={first}\n', self.env_file.read_text())
        self.env.update(TEST_REPO_DIGEST=f'example/site-agent@{second}', TEST_HEALTH_RESULTS='1,0')
        (self.root / 'health-count').unlink()
        self.run_script('update.sh', f'v3@{second}', ok=False)
        saved = self.env_file.read_text()
        self.assertIn('SITE_AGENT_VERSION=v2\n', saved)
        self.assertIn(f'SITE_AGENT_DIGEST={first}\n', saved)

    def test_malformed_digest_is_rejected_before_anything_changes(self):
        self.make_identity()
        self.run_script('update.sh', 'v2@sha256:nothex', ok=False)
        self.assertIn('SITE_AGENT_VERSION=v1\n', self.env_file.read_text())

    def test_failed_rollback_reports_failure(self):
        self.make_identity()
        self.env['TEST_HEALTH_RESULTS'] = '1'
        result = self.run_script('update.sh', 'v2', ok=False)
        self.assertIn('rollback did NOT become healthy', result.stdout)

    def test_same_release_does_not_replace_previous_pin(self):
        self.make_identity()
        with self.env_file.open('a') as stream:
            stream.write('SITE_AGENT_PREV_VERSION=v0\n')
        self.run_script('update.sh', 'v1')
        self.assertIn('SITE_AGENT_PREV_VERSION=v0\n', self.env_file.read_text())

    def test_replacement_hold_blocks_update_before_changing_pin(self):
        self.make_identity()
        (self.storage / 'ipc').mkdir(parents=True, exist_ok=True)
        (self.storage / 'ipc/replacement.json').write_text('{"phase":"staged"}')
        self.run_script('update.sh', 'v2', ok=False)
        self.assertIn('SITE_AGENT_VERSION=v1\n', self.env_file.read_text())
        self.assertFalse(self.log.exists())

    def set_env(self, key, value):
        lines = [line for line in self.env_file.read_text().splitlines() if not line.startswith(key + '=')]
        self.env_file.write_text('\n'.join(lines + [f'{key}={value}']) + '\n')

    def daemon_config(self):
        return json.loads((self.root / 'daemon.json').read_text())

    def test_update_from_mirror_trusts_it_and_forgets_ghcr_login(self):
        self.make_identity()
        (self.root / 'daemon.json').write_text('{"live-restore": true}')
        self.set_env('SITE_AGENT_IMAGE', 'release-mirror:5000/neddia/site-agent')
        self.run_script('update.sh', 'v2')
        config = self.daemon_config()
        self.assertEqual(config['insecure-registries'], ['release-mirror:5000'])
        self.assertTrue(config['live-restore'])
        args = [c['args'] for c in self.commands()]
        self.assertIn(['systemctl', 'reload', 'docker'], args)
        self.assertIn(['logout', 'ghcr.io'], args)
        self.assertFalse(any(a[:1] == ['login'] for a in args))
        # A second update changes nothing and does not reload Docker again.
        self.log.unlink()
        self.run_script('update.sh', 'v2')
        self.assertEqual(self.daemon_config()['insecure-registries'], ['release-mirror:5000'])
        self.assertNotIn(['systemctl', 'reload', 'docker'], [c['args'] for c in self.commands()])

    def test_legacy_ghcr_image_keeps_existing_login(self):
        self.make_identity()
        self.set_env('SITE_AGENT_IMAGE', 'ghcr.io/neddia/site-agent')
        self.run_script('update.sh', 'v2')
        args = [c['args'] for c in self.commands()]
        self.assertNotIn(['logout', 'ghcr.io'], args)
        self.assertFalse((self.root / 'daemon.json').exists())

    def test_preloaded_install_still_trusts_mirror_for_later_updates(self):
        self.set_env('SITE_AGENT_IMAGE', 'release-mirror:5000/neddia/site-agent')
        self.run_script('install.sh')
        self.assertEqual(self.daemon_config()['insecure-registries'], ['release-mirror:5000'])
        self.assertNotIn(['compose', 'pull'], [c['args'] for c in self.commands()])

    def install_with_tailscale(self, states, ok=True):
        self.set_env('SKIP_TAILSCALE', '0')
        self.set_env('TS_AUTHKEY', 'test-only-key')
        self.env['TEST_TAILSCALE_STATES'] = states
        return self.run_script('install.sh', ok=ok)

    def test_install_waits_for_tailnet_approval_and_tells_the_console(self):
        result = self.install_with_tailscale('NeedsLogin,Starting,NeedsMachineAuth,NeedsMachineAuth,Running')
        self.assertEqual(result.stdout.count('waiting for an operator to approve this device'), 1)
        self.assertIn('tailnet approval received', result.stdout)
        up = next(c['args'] for c in self.commands() if c['args'][:2] == ['tailscale', 'up'])
        self.assertIn('--timeout=2m', up)
        self.assertIn(['agetty', '--reload'], [c['args'] for c in self.commands()])
        # The waiting notice is removed once approved.
        self.assertFalse((self.root / 'issue.d/toops-ipc.issue').exists())
        self.assertIn(['compose', 'up', '-d'], [c['args'] for c in self.commands()])

    def test_rejected_auth_key_fails_install_before_starting_stack(self):
        result = self.install_with_tailscale('NeedsLogin', ok=False)
        self.assertIn('Tailscale did not log in', result.stderr)
        self.assertNotIn(['compose', 'up', '-d'], [c['args'] for c in self.commands()])

    def test_unresponsive_tailscale_does_not_wait_forever(self):
        self.env['TAILSCALE_SETTLE_POLLS'] = '3'
        result = self.install_with_tailscale('Starting', ok=False)
        self.assertIn('Tailscale did not settle', result.stderr)

    def prepare_media(self):
        private = self.root / 'private'
        private.mkdir()
        (private / 'seed.env').write_text('TS_AUTHKEY=test-only\nSITE_AGENT_IMAGE=example/site-agent\n')
        (private / 'seed.env').chmod(0o600)
        (private / 'id_ed25519.pub').write_text('ssh-ed25519 test-only')
        iso = self.root / 'base.iso'
        iso.write_bytes(b'fake base ISO')
        images = self.root / 'images'
        images.mkdir()
        (images / 'site-agent-v2.tar.gz').write_bytes(b'fake preloaded image')
        self.env.update(IPC_E2E_PRIVATE_DIR=str(private), UBUNTU_ISO=str(iso),
                        UBUNTU_ISO_SHA256=hashlib.sha256(iso.read_bytes()).hexdigest(),
                        IPC_E2E_CACHE_DIR=str(self.root / 'cache'),
                        IPC_E2E_IMAGE_DIR=str(images), IPC_E2E_IMAGE_TAG='v2',
                        IPC_E2E_SKIP_CLOUD_ENROLLMENT='1')
        return images

    def test_media_build_needs_only_site_agent_archive(self):
        self.prepare_media()
        self.run_script('provision/hyperv/build-media.sh')
        capture = self.root / 'media-capture'
        self.assertEqual([p.name for p in (capture / 'images').iterdir()], ['site-agent-v2.tar.gz'])
        seed = (capture / 'seed.env').read_text()
        self.assertIn('SITE_AGENT_VERSION=v2\n', seed)
        self.assertIn('SKIP_IMAGE_PULL=1\n', seed)
        self.assertNotIn('GATEWAYD', seed)

    def test_media_carries_no_registry_credential_or_customer_account(self):
        self.prepare_media()
        seed = self.root / 'private/seed.env'
        seed.write_text(seed.read_text() + 'GHCR_USER=someone\nGHCR_TOKEN=test-only-token\n')
        self.run_script('provision/hyperv/build-media.sh')
        capture = self.root / 'media-capture'
        self.assertNotIn('GHCR', (capture / 'seed.env').read_text())
        self.assertNotIn('test-only-token', (capture / 'seed.env').read_text())
        user_data = (capture / 'user-data').read_text()
        self.assertNotIn('siteadmin', user_data)
        self.assertNotIn('useradd', user_data)

    def test_each_device_gets_its_own_console_password(self):
        self.prepare_media()
        hashes = {}
        for host in ('ipc-a', 'ipc-b', 'ipc-a'):
            shutil.rmtree(self.root / 'media-capture', ignore_errors=True)
            self.env['IPC_E2E_HOSTNAME'] = host
            self.run_script('provision/hyperv/build-media.sh')
            password_file = self.root / 'private/console-passwords' / host
            self.assertEqual(password_file.stat().st_mode & 0o777, 0o600)
            user_data = (self.root / 'media-capture/user-data').read_text()
            self.assertNotIn(password_file.read_text().strip(), user_data)
            hashes.setdefault(host, set()).add(password_file.read_text())
        self.assertEqual(len(hashes['ipc-a']), 1)  # rebuilding a device reuses its password
        self.assertNotEqual(hashes['ipc-a'], hashes['ipc-b'])

if __name__ == '__main__':
    unittest.main()
