import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

ROOT = Path(__file__).parents[1]


def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


guard = module('identity', 'scripts/ensure-ipc-identity.py')
installer = module('enrollment', 'scripts/install-enrollment.py')
tickets = module('tickets', 'provision/create-enrollment-ticket.py')


class DeviceIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.secrets = self.root / 'secrets'
        self.storage = self.root / 'storage'
        self.host = self.root / 'host'
        self.host.write_text('host-one')
        patcher = patch.dict(os.environ, {'IPC_HARDWARE_ID_FILE': str(self.host)})
        patcher.start(); self.addCleanup(patcher.stop)

    def ensure(self, **kwargs):
        guard.ensure(self.secrets, self.storage, **kwargs)

    def test_repeat_concurrent_and_public_repair_preserve_private_key(self):
        with ThreadPoolExecutor(4) as pool:
            list(pool.map(lambda _: self.ensure(), range(8)))
        original = (self.secrets / 'ipc_ed25519').read_bytes()
        (self.secrets / 'ipc_ed25519.pub').unlink()
        self.ensure()
        self.assertEqual(original, (self.secrets / 'ipc_ed25519').read_bytes())
        self.ensure(validate_only=True)

    def test_fresh_devices_get_different_keys(self):
        self.ensure()
        guard.ensure(self.root / 'other', self.root / 'other-storage')
        self.assertNotEqual((self.secrets / 'ipc_ed25519.pub').read_bytes(), (self.root / 'other/ipc_ed25519.pub').read_bytes())

    def test_missing_private_never_regenerates(self):
        self.ensure()
        public = (self.secrets / 'ipc_ed25519.pub').read_bytes()
        (self.secrets / 'ipc_ed25519').unlink()
        with self.assertRaises(ValueError): self.ensure()
        self.assertFalse((self.secrets / 'ipc_ed25519').exists())
        self.assertEqual(public, (self.secrets / 'ipc_ed25519.pub').read_bytes())

    def test_corrupt_private_and_mismatched_public_fail(self):
        self.ensure()
        private = self.secrets / 'ipc_ed25519'
        original = private.read_bytes()
        private.write_bytes(b'')
        with self.assertRaises(subprocess.CalledProcessError): self.ensure()
        private.write_bytes(original)
        (self.secrets / 'ipc_ed25519.pub').write_text('wrong')
        with self.assertRaises(ValueError): self.ensure()

    def test_cloned_host_and_missing_identity_on_update_fail(self):
        with self.assertRaises(ValueError): self.ensure(validate_only=True)
        self.ensure()
        self.host.write_text('different-host')
        with self.assertRaises(ValueError): self.ensure()

    def test_existing_receipt_blocks_fresh_identity(self):
        (self.storage / 'ipc').mkdir(parents=True)
        (self.storage / 'ipc/hardware.json').write_text('{}')
        with self.assertRaises(ValueError): self.ensure()

    def test_ticket_install_is_idempotent_and_holds_only_unpaired(self):
        self.ensure()
        ticket = {'cloud_url': 'https://cloud.example', 'token': 'test-only'}
        source = self.root / 'cloud-enrollment.json'
        source.write_text(json.dumps(ticket))
        for _ in range(2): installer.install(self.root, self.secrets, self.storage, ticket['cloud_url'])
        hold = self.storage / 'ipc/enrollment-hold.json'
        self.assertTrue(hold.exists())
        hold.unlink()
        (self.storage / 'ipc/identity.json').write_text('{}')
        installer.install(self.root, self.secrets, self.storage, ticket['cloud_url'])
        self.assertFalse(hold.exists())
        source.write_text(json.dumps({**ticket, 'token': 'different'}))
        with self.assertRaises(ValueError): installer.install(self.root, self.secrets, self.storage, ticket['cloud_url'])

    def test_builder_retries_same_ticket_without_copying_issuer(self):
        config = self.root / 'installer.json'
        config.write_text(json.dumps({'cloud_url': 'https://cloud.example', 'credential': 'installer-test-only'}))
        config.chmod(0o600)
        output = self.root / 'ticket.json'
        requests = []
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return json.dumps({'id': requests[-1]['request_id']}).encode()
        class Opener:
            def open(self, request, timeout):
                requests.append(json.loads(request.data))
                return Response()
        with patch.object(tickets.urllib.request, 'build_opener', return_value=Opener()):
            tickets.create(config, output, 'spare')
            tickets.create(config, output, 'spare')
        self.assertEqual(requests[0], requests[1])
        self.assertNotIn('installer-test-only', output.read_text())
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        config.chmod(0o644)
        with self.assertRaises(ValueError): tickets.create(config, output, 'spare')


if __name__ == '__main__': unittest.main()
