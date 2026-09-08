from pathlib import Path
import subprocess
import unittest

class LockdownTests(unittest.TestCase):
    def script(self):
        path=Path(__file__).resolve().parents[1]/'scripts/lockdown-ssh.sh'
        return path.read_text().rsplit('main "$@"',1)[0]

    def test_empty_ufw_ruleset_gets_required_allow_before_deny(self):
        result=subprocess.run(['bash'],input=self.script()+'''
install_ufw_if_missing() { :; }
exec 3>&1
ufw() { echo "$*" >&3; if [[ "$1" == insert ]]; then return 1; fi; }
configure_ufw
''',text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertLess(result.stdout.index('allow in on tailscale0 to any port 22'),result.stdout.index('deny in 22/tcp'))

    def test_sshd_detection_uses_unit_state_not_short_circuit_pipeline(self):
        result=subprocess.run(['bash'],input=self.script()+'''
ensure_privsep_dir() { :; }
sshd() { return 0; }
systemctl() { if [[ "$1" == show && "$2" == ssh.service ]]; then echo loaded; else echo "systemctl $*"; fi; }
service() { echo WRONG_FALLBACK; return 1; }
ss() { :; }
validate_and_restart_sshd
''',text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('systemctl restart ssh',result.stdout)
        self.assertNotIn('WRONG_FALLBACK',result.stdout)

if __name__=='__main__':unittest.main()
