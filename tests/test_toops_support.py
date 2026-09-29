"""Exercise toops-support against fake host commands in a temporary directory."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/toops-support.sh'


class ToopsSupportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands.log'
        self.dropin = self.root / 'sshd_config.d/50-toops-support-off.conf'
        for name in ('systemctl', 'loginctl', 'logger', 'journalctl', 'iptables', 'chown'):
            self.fake(name, 'exit 0')
        self.fake('sshd', 'exit "${TEST_SSHD_RESULT:-0}"')
        peers = {'Peer': {'gw': {'Tags': ['tag:gateway'], 'TailscaleIPs': ['100.64.0.9', 'fd7a::9']},
                          'laptop': {'Tags': [], 'TailscaleIPs': ['100.64.0.2']}}}
        self.fake('tailscale', f"echo '{json.dumps(peers)}'")
        self.request = self.root / 'ipc/support-access-request.json'
        self.status = self.root / 'ipc/support-access.json'
        self.env = {'PATH': f'{self.bin}{os.pathsep}{os.defpath}', 'TEST_LOG': str(self.log),
                    'TOOPS_SUPPORT_DROPIN': str(self.dropin), 'SUDO_USER': 'operator',
                    'TOOPS_SUPPORT_REQUEST': str(self.request), 'TOOPS_SUPPORT_STATUS': str(self.status)}

    def fake(self, name, body):
        path = self.bin / name
        path.write_text(f'#!/bin/sh\necho "{name} $*" >>"$TEST_LOG"\n{body}\n')
        path.chmod(0o755)

    def run_support(self, *args, ok=True):
        # The root guard is the only thing skipped; everything else is real.
        text = SCRIPT.read_text().replace('[ "${EUID:-$(id -u)}" -eq 0 ]', 'true')
        result = subprocess.run(['bash', '-c', text, 'toops-support', *args], env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_off_denies_support_user_ends_sessions_and_is_recorded(self):
        result = self.run_support('off')
        self.assertIn('DenyUsers toops', self.dropin.read_text())
        self.assertIn('systemctl try-reload-or-restart ssh.service', self.calls())
        self.assertIn('loginctl terminate-user toops', self.calls())
        self.assertIn('logger -t toops-support Toops support access disabled by operator', self.calls())
        self.assertIn('OFF', result.stdout)
        calls = self.calls()
        self.assertLess(calls.index('logger -t toops-support Toops support access disabled by operator'), calls.index('loginctl terminate-user toops'))

    def test_on_removes_the_denial(self):
        self.run_support('off')
        self.run_support('on')
        self.assertFalse(self.dropin.exists())
        self.assertIn('logger -t toops-support Toops support access enabled by operator', self.calls())

    def test_rejected_sshd_config_leaves_access_unchanged(self):
        self.env['TEST_SSHD_RESULT'] = '1'
        self.run_support('off', ok=False)
        self.assertFalse(self.dropin.exists())
        self.assertNotIn('loginctl terminate-user toops', self.calls())

    def test_status_reports_current_setting(self):
        self.assertIn('Toops support access: ON', self.run_support('status').stdout)
        self.run_support('off')
        self.assertIn('Toops support access: OFF', self.run_support('status').stdout)

    def test_off_drops_tailnet_ui_except_cloud_gateway(self):
        self.run_support('off')
        rules = [c for c in self.calls() if c.startswith('iptables -A TOOPS-SUPPORT')]
        self.assertEqual(rules[0], 'iptables -A TOOPS-SUPPORT -i tailscale0 -s 100.64.0.9 -p tcp -m conntrack --ctorigdstport 8000 -j RETURN')
        self.assertIn('iptables -A TOOPS-SUPPORT -i tailscale0 -p tcp -m conntrack --ctorigdstport 8000 -j DROP', rules)
        self.assertFalse(any('100.64.0.2' in rule for rule in rules))
        status = json.loads(self.status.read_text())
        self.assertEqual((status['enabled'], status['tailnet_ui_blocked'], status['cloud_gateways_allowed']), (False, True, 1))

    def test_on_removes_the_tailnet_block(self):
        self.run_support('off')
        self.log.unlink()
        self.run_support('on')
        rules = [c for c in self.calls() if c.startswith('iptables -A TOOPS-SUPPORT')]
        self.assertEqual(rules, ['iptables -A TOOPS-SUPPORT -j RETURN'])
        self.assertTrue(json.loads(self.status.read_text())['enabled'])

    def test_apply_follows_the_dashboard_request(self):
        self.request.parent.mkdir(parents=True)
        self.request.write_text(json.dumps({'enabled': False}))
        self.run_support('apply')
        self.assertTrue(self.dropin.exists())
        self.assertIn('loginctl terminate-user toops', self.calls())
        self.request.write_text(json.dumps({'enabled': True}))
        self.run_support('apply')
        self.assertFalse(self.dropin.exists())

    def test_apply_ignores_malformed_request_and_keeps_current_state(self):
        self.run_support('off')
        self.request.write_text(json.dumps({'enabled': 'yes'}))
        self.run_support('apply')
        self.assertTrue(self.dropin.exists())

    def test_repeated_apply_does_not_end_sessions_again(self):
        self.run_support('off')
        self.log.unlink()
        self.run_support('apply')
        self.assertNotIn('loginctl terminate-user toops', self.calls())

    def test_console_switch_is_remembered_for_the_next_apply(self):
        self.run_support('off')
        self.assertFalse(json.loads(self.request.read_text())['enabled'])
        self.run_support('apply')
        self.assertTrue(self.dropin.exists())

    def test_unknown_command_prints_usage(self):
        result = self.run_support('maybe', ok=False)
        self.assertIn('sudo toops-support off', result.stdout)


if __name__ == '__main__':
    unittest.main()
