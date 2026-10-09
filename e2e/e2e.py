#!/usr/bin/env python3
"""Helpers for the Basin end-to-end run (run.py): state, SSH, Cloud/edge/plant APIs."""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path

import httpx

HERE = Path(__file__).resolve().parent
PRIVATE = Path(os.environ.get("IPC_E2E_PRIVATE_DIR", Path.home() / ".config/toops-e2e"))
CACHE = Path(os.environ.get("IPC_E2E_CACHE_DIR", Path.home() / ".cache/toops-e2e"))
STATE_PATH = CACHE / "run" / "state.json"
WIN_ROOT = Path("/mnt/c/Users/Aidden/AppData/Local/toops-e2e")
CA_BUNDLE = PRIVATE / "cloud-e2e" / "ca-bundle.pem"
ADMIN_EMAIL = os.environ.get("E2E_ADMIN_EMAIL", "neddia1@gmail.com")
CUSTOMER_EMAIL = os.environ.get("E2E_CUSTOMER_EMAIL", "neddia1+e2e-owner@gmail.com")


# ------------------------------------------------------------------ state/log
def load() -> dict:
    return json.loads(STATE_PATH.read_text()) if STATE_PATH.exists() else {}


def save(state: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, default=str))
    os.chmod(tmp, 0o600)
    tmp.replace(STATE_PATH)


def log(msg: str) -> None:
    print(f"[e2e {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def note(state: dict, kind: str, text: str) -> None:
    """Findings collected during the run: kind is pass, fail, gap, pain or fixed."""
    state.setdefault("findings", []).append({"t": time.strftime("%Y-%m-%d %H:%M:%S"), "kind": kind, "text": text})
    save(state)
    log(f"{kind.upper()}: {text}")


# ------------------------------------------------------------------ hosts
# WSL cannot route to the Hyper-V Default Switch; Windows can. A Windows-side
# relay (win-relay.py) carries SSH, and SSH forwards carry everything else.
RELAY = os.environ.get("E2E_SSH_RELAY", "/mnt/c/msys64/ucrt64/bin/python.exe C:/Users/Aidden/AppData/Local/toops-e2e/win-relay.py %h %p")


def ssh_cmd(ip: str) -> list[str]:
    return ["ssh", "-i", str(PRIVATE / "id_ed25519"), "-o", f"ProxyCommand={RELAY}", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10",
            f"toops@{ip}"]


def ssh(ip: str, command: str, *, check: bool = True, input: str | None = None, timeout: int = 600) -> str:
    result = subprocess.run(ssh_cmd(ip) + [command], input=input, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"ssh {ip}: {command[:120]} -> {result.returncode}\n{result.stderr[-2000:]}")
    return result.stdout


def ipc_sudo(state: dict, command: str, *, check: bool = True, timeout: int = 600) -> str:
    """Root on the test IPC the way an operator gets it: sudo with that box's console password."""
    password = (PRIVATE / "cloud-e2e" / "private" / "console-passwords" / state["ipc_hostname"]).read_text().strip()
    return ssh(state["ipc_ip"], f"sudo -S -p '' bash -c {shlex.quote(command)}", input=password + "\n",
               check=check, timeout=timeout)


def ipc_put(state: dict, local_bytes: bytes, remote_path: str, mode: str = "0644") -> None:
    """Copy bytes to a root-owned path on the IPC (staged in the operator's home, then installed with sudo)."""
    tmp = f"/home/toops/.e2e-upload-{uuid.uuid4().hex}"
    subprocess.run(ssh_cmd(state["ipc_ip"]) + [f"cat > {tmp}"], input=local_bytes, check=True)
    ipc_sudo(state, f"install -D -m {mode} {tmp} {shlex.quote(remote_path)} && rm -f {tmp}")


def powershell(script: str, *args: str, timeout: int = 7200) -> str:
    path = subprocess.run(["wslpath", "-w", str(script)], capture_output=True, text=True).stdout.strip()
    result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path, *args],
                            capture_output=True, text=True, timeout=timeout)
    out = result.stdout.replace("\r", "")
    if result.returncode:
        raise RuntimeError(f"powershell {script}: {out[-1500:]} {result.stderr[-1500:]}")
    return out


def cloud_compose(state: dict) -> str:
    return f"cd /opt/toops-cloud && E2E_IP={state['cloud_ip']} docker compose -f compose.yml -f compose.e2e.yml"


def cloud_python(state: dict, code: str) -> str:
    """Run Python inside the test Cloud's api container."""
    return ssh(state["cloud_ip"], f"{cloud_compose(state)} exec -T api python -", input=code)


# ------------------------------------------------------------------ cloud API
PROXY = "http://127.0.0.1:13128"


def ensure_proxy() -> None:
    """Start connect-proxy.py (WSL -> Windows -> Default Switch) if it is not running."""
    import socket
    try:
        socket.create_connection(("127.0.0.1", 13128), timeout=2).close()
        return
    except OSError:
        pass
    logf = open(CACHE / "run" / "connect-proxy.log", "a")
    subprocess.Popen([sys.executable, str(HERE / "connect-proxy.py")], stdout=logf, stderr=logf,
                     stdin=subprocess.DEVNULL, start_new_session=True)
    time.sleep(2)


class Cloud:
    def __init__(self, state: dict, token_key: str = "admin_token"):
        ensure_proxy()
        self.base = f"https://{state['cloud_ip']}"
        self.client = httpx.Client(base_url=self.base, proxy=PROXY, verify=str(CA_BUNDLE), timeout=60,
                                   cookies={"toops_session": state[token_key]} if state.get(token_key) else None)

    def call(self, method: str, path: str, body: dict | None = None, *, ok=(200, 201)) -> dict:
        response = self.client.request(method, path, json=body)
        if response.status_code not in ok:
            raise RuntimeError(f"{method} {path} -> {response.status_code}: {response.text[:800]}")
        return response.json() if response.content else {}

    def get(self, path: str, **kw) -> dict:
        return self.call("GET", path, **kw)

    def post(self, path: str, body: dict | None = None, **kw) -> dict:
        return self.call("POST", path, body, **kw)


def mint_session(state: dict, *, email: str, sub: str) -> str:
    """Log a user in the way /auth/callback would, with MFA (aal2). Local test Cloud only."""
    code = f"""
from app.auth import upsert_user, apply_pending_invites, create_session
uid = upsert_user({sub!r}, {email!r})
apply_pending_invites(uid, {email!r})
print(create_session(uid, auth_aal='aal2'))
"""
    return cloud_python(state, code).strip().splitlines()[-1]


def sql(state: dict, query: str) -> str:
    return ssh(state["cloud_ip"], f"{cloud_compose(state)} exec -T postgres psql -U toops -d toops -At -F '|' -c {shlex.quote(query)}")


# ------------------------------------------------------------------ IPC
def edge(state: dict, method: str, path: str, body: dict | None = None, *, timeout: int = 120) -> dict:
    """Call the controller's local API from the controller itself (LAN UI is not exposed to WSL)."""
    data = json.dumps(body) if body is not None else ""
    cmd = (f"curl -sS -m {timeout} -X {method} -H 'Content-Type: application/json' "
           f"{'--data-binary @-' if body is not None else ''} -w '\\n%{{http_code}}' http://127.0.0.1:8000{path}")
    out = ssh(state["ipc_ip"], cmd, input=data, timeout=timeout + 30)
    text, _, status = out.rstrip("\n").rpartition("\n")
    try:
        payload = json.loads(text) if text.strip() else {}
    except ValueError:
        payload = {"_raw": text[:2000]}
    if not status.startswith("2"):
        raise RuntimeError(f"edge {method} {path} -> {status}: {text[:1500]}")
    return payload


def plant(state: dict, method: str = "GET", path: str = "/state", body: dict | None = None) -> dict:
    data = json.dumps(body) if body is not None else ""
    cmd = f"curl -sS -X {method} {'--data-binary @-' if body else ''} http://127.0.0.1:8099{path}"
    return json.loads(ssh(state["ipc_ip"], cmd, input=data))


def wait(what: str, check, *, timeout: float, every: float = 10.0):
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            value = check()
            if value:
                return value
        except Exception as exc:  # noqa: BLE001 - polling through transient failures
            last_error = exc
        time.sleep(every)
    raise TimeoutError(f"timed out waiting for {what}" + (f" (last error: {last_error})" if last_error else ""))
