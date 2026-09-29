"""Run configure-logging.sh against temporary config files and a fake systemctl."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/configure-logging.sh'


class ConfigureLoggingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'systemctl.log'
        systemctl = self.bin / 'systemctl'
        systemctl.write_text('#!/bin/sh\necho "$*" >>"$TEST_LOG"\n'
                             '[ "$1" = is-active ] && exit "${TEST_DOCKER_INACTIVE:-0}"\nexit 0\n')
        systemctl.chmod(0o755)
        self.daemon = self.root / 'docker/daemon.json'
        self.journald = self.root / 'journald.conf.d/size-limit.conf'
        self.env = {'PATH': f'{self.bin}{os.pathsep}{os.defpath}', 'TEST_LOG': str(self.log),
                    'DOCKER_DAEMON_JSON': str(self.daemon), 'JOURNALD_DROPIN': str(self.journald)}

    def run_script(self, ok=True):
        result = subprocess.run(['bash', str(SCRIPT)], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_merges_into_existing_config_and_asks_for_recreation(self):
        self.daemon.parent.mkdir()
        self.daemon.write_text(json.dumps({'insecure-registries': ['release-mirror:5000'], 'log-driver': 'json-file',
                                           'log-opts': {'max-size': '20m', 'max-file': '5'}}))
        result = self.run_script()
        config = json.loads(self.daemon.read_text())
        self.assertEqual(config['insecure-registries'], ['release-mirror:5000'])
        self.assertEqual(config['log-driver'], 'journald')
        self.assertEqual(config['log-opts'], {'tag': '{{.Name}}'})
        self.assertTrue(config['live-restore'])
        self.assertEqual(result.stdout.strip(), 'recreate')
        self.assertIn('restart docker', self.calls())
        self.assertIn('SystemMaxUse=1G', self.journald.read_text())
        self.assertIn('Storage=persistent', self.journald.read_text())

    def test_second_run_changes_and_restarts_nothing(self):
        self.run_script()
        self.log.unlink()
        result = self.run_script()
        self.assertEqual(result.stdout.strip(), '')
        self.assertFalse([c for c in self.calls() if c.startswith('restart')])

    def test_fresh_install_before_docker_runs_does_not_restart_it(self):
        self.env['TEST_DOCKER_INACTIVE'] = '3'
        result = self.run_script()
        self.assertEqual(result.stdout.strip(), 'recreate')
        self.assertNotIn('restart docker', self.calls())
        self.assertEqual(json.loads(self.daemon.read_text())['log-driver'], 'journald')

    def test_invalid_daemon_json_is_left_alone(self):
        self.daemon.parent.mkdir()
        self.daemon.write_text('{not json')
        self.run_script(ok=False)
        self.assertEqual(self.daemon.read_text(), '{not json')
        self.assertNotIn('restart docker', self.calls())


if __name__ == '__main__':
    unittest.main()
