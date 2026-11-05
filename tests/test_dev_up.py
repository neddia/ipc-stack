from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

STACK = Path(__file__).resolve().parents[1]

SEEDER = '''import shutil, sys
from pathlib import Path
src = Path(__file__).resolve().parents[2] / "storage/sim-data/site-profiles"
for path in src.rglob("*.yaml"):
    target = Path(sys.argv[1]) / path.relative_to(src)
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
'''


class DevUpSimProfileTests(unittest.TestCase):
    """dev-up.sh seeds setpoint's sim site models before any container starts."""

    def run_dev_up(self, root, *, with_seeder=True, tailwind=False, make_body=None, expect_ok=True):
        stack = root / 'ipc-stack'
        (stack / 'scripts').mkdir(parents=True)
        shutil.copy(STACK / 'dev-up.sh', stack / 'dev-up.sh')
        for name in ('gen-ipc-secrets.sh', 'bootstrap-influx.sh'):
            (stack / 'scripts' / name).write_text('#!/usr/bin/env bash\nexit 0\n')
            (stack / 'scripts' / name).chmod(0o755)
        (stack / '.env.dev').write_text(f'ENABLE_TAILWIND={1 if tailwind else 0}\n')
        setpoint = root / 'setpoint'
        fixture = setpoint / 'storage/sim-data/site-profiles/models/demo/rev.yaml'
        fixture.parent.mkdir(parents=True)
        fixture.write_text('id: demo\n')
        if with_seeder:
            (setpoint / 'tools/sims').mkdir(parents=True)
            (setpoint / 'tools/sims/sim_profiles.py').write_text(SEEDER)
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        # The stub records whether the models were there when compose ran.
        seeded = setpoint / 'storage/site-profiles/models/demo/rev.yaml'
        (bin_dir / 'docker').write_text(
            f'#!/usr/bin/env bash\n[ -f "{seeded}" ] && echo seeded >> "{root}/docker.log" '
            f'|| echo missing >> "{root}/docker.log"\n')
        (bin_dir / 'docker').chmod(0o755)
        (bin_dir / 'tailscale').write_text('#!/usr/bin/env bash\nexit 1\n')
        (bin_dir / 'tailscale').chmod(0o755)
        # The stub records each call, then does what the real target would.
        (bin_dir / 'make').write_text(
            f'#!/usr/bin/env bash\necho "$@" >> "{root}/make.log"\n{make_body or "exit 1"}\n')
        (bin_dir / 'make').chmod(0o755)
        env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}',
               'IPC_SECRETS_DIR': str(root / 'secrets')}
        for key in ('SETPOINT_DIR', 'IPC_STORAGE_DIR', 'ENABLE_SIM', 'BUILD_IMAGES', 'ENABLE_TAILWIND'):
            env.pop(key, None)
        result = subprocess.run(['bash', str(stack / 'dev-up.sh'), str(stack / '.env.dev')],
                                cwd=root, env=env, text=True, capture_output=True)
        if not expect_ok:
            self.assertNotEqual(result.returncode, 0)
            return result
        self.assertEqual(result.returncode, 0, result.stderr)
        return seeded, (root / 'docker.log').read_text().split()

    def fetch_body(self, root):
        tailwind = root / 'setpoint/bin/tailwindcss'
        return f'mkdir -p "{tailwind.parent}"\ntouch "{tailwind}"'

    def test_missing_tailwind_binary_is_fetched_before_compose(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.run_dev_up(root, tailwind=True, make_body=self.fetch_body(root))
            self.assertTrue((root / 'setpoint/bin/tailwindcss').is_file())
            self.assertIn('bin/tailwindcss', (root / 'make.log').read_text())

    def test_existing_tailwind_binary_is_not_fetched_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            existing = root / 'setpoint/bin/tailwindcss'
            existing.parent.mkdir(parents=True)
            existing.write_text('binary\n')
            self.run_dev_up(root, tailwind=True)
            self.assertFalse((root / 'make.log').exists())

    def test_failed_tailwind_fetch_stops_before_compose(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.run_dev_up(root, tailwind=True, expect_ok=False)
            self.assertIn('ENABLE_TAILWIND=0', result.stderr)
            self.assertFalse((root / 'docker.log').exists())
            self.assertFalse((root / 'setpoint/bin/tailwindcss').exists())

    def test_tailwind_disabled_does_not_fetch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.run_dev_up(root, tailwind=False)
            self.assertFalse((root / 'make.log').exists())

    def test_missing_models_are_seeded_before_compose(self):
        with tempfile.TemporaryDirectory() as tmp:
            seeded, calls = self.run_dev_up(Path(tmp))
            self.assertEqual(seeded.read_text(), 'id: demo\n')
            self.assertTrue(calls)
            self.assertEqual(set(calls), {'seeded'})

    def test_existing_site_profiles_are_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            local = root / 'setpoint/storage/site-profiles/models/demo/rev.yaml'
            local.parent.mkdir(parents=True)
            local.write_text('local\n')
            seeded, _ = self.run_dev_up(root)
            self.assertEqual(seeded.read_text(), 'local\n')

    def test_older_setpoint_without_the_seeder_still_starts(self):
        with tempfile.TemporaryDirectory() as tmp:
            seeded, calls = self.run_dev_up(Path(tmp), with_seeder=False)
            self.assertFalse(seeded.exists())
            self.assertTrue(calls)


if __name__ == '__main__':
    unittest.main()
