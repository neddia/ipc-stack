from pathlib import Path
import os
import subprocess
import tempfile
import unittest


def security_updates_function():
    lines = (Path(__file__).resolve().parents[1] / 'scripts/bootstrap-host.sh').read_text().splitlines()
    start = lines.index('security_updates() {')
    end = lines.index('}', start)
    return '\n'.join(lines[start:end + 1])


class SecurityUpdateTests(unittest.TestCase):
    def run_with(self, reboot_time):
        with tempfile.TemporaryDirectory() as root:
            conf = Path(root) / 'apt.conf.d'
            conf.mkdir()
            script = security_updates_function().replace('/etc/apt/apt.conf.d', str(conf))
            env = {**os.environ, 'IPC_AUTO_REBOOT_TIME': reboot_time}
            result = subprocess.run(['bash'], input='log() { :; }\napt_install() { return 0; }\n'
                                    'systemctl() { :; }\n' + script + '\nsecurity_updates\n',
                                    text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            return ((conf / '20auto-upgrades').read_text(),
                    (conf / '51unattended-upgrades-security-only').read_text())

    def test_daily_security_updates_are_enabled_explicitly(self):
        periodic, policy = self.run_with('')
        self.assertIn('APT::Periodic::Unattended-Upgrade "1";', periodic)
        self.assertIn('"${distro_id}:${distro_codename}-security";', policy)

    def test_tailscale_updates_but_docker_does_not(self):
        _, policy = self.run_with('')
        self.assertIn('"origin=Tailscale,label=Tailscale,site=pkgs.tailscale.com";', policy)
        self.assertNotIn('origin=Docker', policy)
        self.assertNotIn('download.docker.com', policy)

    def test_reboots_stay_off_without_a_site_time(self):
        _, policy = self.run_with('')
        self.assertIn('Unattended-Upgrade::Automatic-Reboot "false";', policy)
        self.assertNotIn('Automatic-Reboot-Time', policy)

    def test_a_site_time_enables_reboots_only_then(self):
        _, policy = self.run_with('03:30')
        self.assertIn('Unattended-Upgrade::Automatic-Reboot "true";', policy)
        self.assertIn('Unattended-Upgrade::Automatic-Reboot-Time "03:30";', policy)


if __name__ == '__main__':
    unittest.main()
