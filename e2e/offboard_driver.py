"""Run provision/offboard-controller.sh unmodified, answering its prompts like an operator (e2e only).
  uv run --with pexpect python offboard_driver.py <host> <console-password-file>"""
import sys
import pexpect

host, password_file = sys.argv[1], sys.argv[2]
password = open(password_file).read().strip()
child = pexpect.spawn("bash", [str(__import__("pathlib").Path.home() / "ipc-stack/provision/offboard-controller.sh"), host],
                      encoding="utf-8", timeout=600)
child.logfile_read = sys.stdout
while True:
    i = child.expect([r"Type 'no backup': ", r"Type 'handed back': ", r"Type the controller hostname to confirm: ",
                      r"\[sudo\] password for \w+: ", pexpect.EOF])
    if i == 0:
        child.sendline("no backup")       # the run log records that the backup failed
    elif i == 1:
        child.sendline("handed back")
    elif i == 2:
        child.sendline(host)
    elif i == 3:
        child.sendline(password)
    else:
        break
child.close()
sys.exit(child.exitstatus or 0)
