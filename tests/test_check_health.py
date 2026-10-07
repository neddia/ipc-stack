"""Run check-health.sh against fake docker/curl: slow starts, crash loops, site faults."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check-health.sh'


class CheckHealthTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        secrets = self.root / 'secrets'
        secrets.mkdir()
        (secrets / 'influx.admin.token').write_text('token')
        self.env_file = self.root / '.env'
        self.env_file.write_text(f'IPC_SECRETS_DIR={secrets}\nIPC_STORAGE_DIR={self.root / "storage"}\n')
        # Each status poll consumes the next entry; the last one repeats.
        self.statuses = self.root / 'statuses.json'
        self.restarts = self.root / 'restarts.json'
        self.status([{'startup_complete': True, 'startup_errors': []}])
        self.restart_counts([0])
        self.equipment = self.root / 'equipment.json'
        self.equipment.write_text(json.dumps([4]))
        self.fake('docker', r'''
import json, os, pathlib, sys
args = sys.argv[1:]
if 'ps' in args and '--services' in args:
    print('influxdb\nsite-agent\ntelegraf')
elif 'ps' in args and '-q' in args:
    print('cid')
elif args[:1] == ['inspect']:
    print(next_value(os.environ['TEST_RESTARTS']))
''')
        self.fake('curl', r'''
import json, os, sys
url = sys.argv[-1]
if url.endswith('/health'):
    print('{"status":"pass"}')
elif '/api/v2/query' in url:
    print('#datatype,string\n,result,table,_time\n,_result,0,2026-01-01T00:00:00Z')
elif url.endswith('/api/equipment/telemetry'):
    online = next_value(os.environ['TEST_EQUIPMENT'])
    if online is None:
        sys.exit(7)
    print(json.dumps({'fans': [{'driver': {'online': True}}] * online + [{'driver': {'online': False}}]}))
elif url.endswith('/ui/service/status'):
    value = next_value(os.environ['TEST_STATUSES'])
    if value is None:
        sys.exit(7)
    print(json.dumps(value))
''')
        self.env = {'PATH': f'{self.bin}{os.pathsep}{os.defpath}', 'TEST_STATUSES': str(self.statuses),
                    'TEST_RESTARTS': str(self.restarts), 'TEST_EQUIPMENT': str(self.equipment),
                    'IPC_HEALTH_SOAK_POLL_S': '0'}

    def fake(self, name, body):
        helper = '''#!/usr/bin/env python3
import json, pathlib
def next_value(path):
    p = pathlib.Path(path)
    values = json.loads(p.read_text())
    value = values[0]
    if len(values) > 1:
        p.write_text(json.dumps(values[1:]))
    return value
'''
        path = self.bin / name
        path.write_text(helper + body)
        path.chmod(0o755)

    def status(self, values):
        self.statuses.write_text(json.dumps(values))

    def restart_counts(self, values):
        self.restarts.write_text(json.dumps(values))

    def run_check(self, *args, ok=True, timeout='30'):
        # sleep is the only builtin-free delay; make it instant.
        self.fake('sleep', '')
        result = subprocess.run(['bash', str(SCRIPT), '--env-file', str(self.env_file), '--timeout', timeout, *args],
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def baseline(self, errors, known=True, drives=None):
        path = self.root / 'baseline.json'
        path.write_text(json.dumps({'known': known, 'errors': errors, 'drives_online': drives}))
        return str(path)

    def equipment_sequence(self, values):
        self.equipment.write_text(json.dumps(values))

    def test_waits_through_a_slow_start(self):
        self.status([None, None, None, {'startup_complete': True, 'startup_errors': []}])
        self.assertIn('stack healthy', self.run_check().stdout)

    def test_crash_loop_fails_without_waiting_out_the_timeout(self):
        self.status([None])
        self.restart_counts([0, 1, 2, 3])
        result = self.run_check(ok=False, timeout='600')
        self.assertIn('site_agent_crash_looping', result.stderr)

    def test_new_startup_error_fails_the_release(self):
        self.status([{'startup_complete': True, 'startup_errors': ['optimizer']}])
        result = self.run_check('--baseline', self.baseline([]), ok=False)
        self.assertIn('site_agent_startup_failed:optimizer', result.stderr)

    def test_error_the_old_release_also_had_is_not_blamed_on_the_update(self):
        self.status([{'startup_complete': True, 'startup_errors': ['VFD telemetry']}])
        self.run_check('--baseline', self.baseline(['VFD telemetry']))

    def test_config_that_no_longer_applies_fails_the_release(self):
        self.status([{'startup_complete': True, 'startup_errors': [], 'apply_error': 'bad field'}])
        result = self.run_check('--baseline', self.baseline([]), ok=False)
        self.assertIn('config apply', result.stderr)

    def test_unknown_baseline_keeps_the_lenient_check(self):
        self.status([{'startup_complete': True, 'startup_errors': ['optimizer']}])
        self.run_check('--baseline', self.baseline([], known=False))

    def test_restart_during_soak_fails(self):
        self.restart_counts([0, 0, 0, 1])
        result = self.run_check('--soak', '5', ok=False)
        self.assertIn('site_agent_restarted_after_start', result.stderr)

    def test_capture_records_running_release_errors_and_drives(self):
        self.status([{'startup_complete': True, 'startup_errors': ['VFD telemetry']}])
        target = self.root / 'captured.json'
        self.run_check('--capture-baseline', str(target))
        self.assertEqual(json.loads(target.read_text()), {'known': True, 'errors': ['VFD telemetry'], 'drives_online': 4})

    def test_update_that_loses_every_drive_fails_after_soak(self):
        self.equipment_sequence([0])
        result = self.run_check('--baseline', self.baseline([], drives=4), '--soak', '1', ok=False)
        self.assertIn('equipment_lost: 0 of 4 drives reachable', result.stderr)

    def test_one_flaky_drive_of_four_is_tolerated(self):
        self.equipment_sequence([3])
        self.run_check('--baseline', self.baseline([], drives=4), '--soak', '1')

    def test_brief_loss_that_recovers_is_not_a_failure(self):
        self.equipment_sequence([0, 4])
        self.run_check('--baseline', self.baseline([], drives=4), '--soak', '1')

    def test_unreadable_equipment_is_not_counted_as_lost(self):
        self.equipment_sequence([None])
        self.run_check('--baseline', self.baseline([], drives=4), '--soak', '1')

    def test_no_soak_skips_the_equipment_comparison(self):
        self.equipment_sequence([0])
        self.run_check('--baseline', self.baseline([], drives=4))

    def test_capture_of_unreachable_site_agent_is_unknown_and_never_fails(self):
        self.status([None])
        target = self.root / 'captured.json'
        self.run_check('--capture-baseline', str(target))
        self.assertEqual(json.loads(target.read_text())['known'], False)


if __name__ == '__main__':
    unittest.main()
