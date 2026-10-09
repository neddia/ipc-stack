#!/usr/bin/env python3
"""Basin end-to-end run against disposable Hyper-V VMs (development only).

State lives in ~/.cache/toops-e2e/run/state.json so stages can be re-run or
resumed. Run with the setpoint venv (httpx):
  uv run --project ~/setpoint python ~/ipc-stack/e2e/run.py <stage> [args]
  ... run.py state | findings
See e2e/README.md for the stage order.
"""
from __future__ import annotations

import argparse
import json

from e2e import *  # noqa: F401,F403
from e2e import load, save

STAGES = {}


def stage(fn):
    STAGES[fn.__name__.replace("_", "-")] = fn
    return fn


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stage", choices=sorted(STAGES) + ["state", "findings"])
    parser.add_argument("args", nargs="*")
    args = parser.parse_args()
    state = load()
    if args.stage == "state":
        print(json.dumps({k: v for k, v in state.items() if "token" not in k and k != "findings"}, indent=2))
        return
    if args.stage == "findings":
        for row in state.get("findings", []):
            print(f"{row['t']}  {row['kind']:<6} {row['text']}")
        return
    try:
        STAGES[args.stage](state, *args.args)
    finally:
        save(state)


# ---------------------------------------------------------------- stages
def _vm(state: dict, name: str, iso: Path, *, cpus: int, mem_gb: int, disk_gb: int) -> str:
    """Create a Hyper-V VM from an installer ISO, wait for the install, boot it, return its IPv4."""
    win_iso = WIN_ROOT / "media" / name / iso.name
    win_iso.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", str(iso), str(win_iso)], check=True)
    vhd = WIN_ROOT / "vm" / f"{name}.vhdx"
    to_win = lambda p: subprocess.run(["wslpath", "-w", str(p)], capture_output=True, text=True).stdout.strip()
    hyperv = Path.home() / "ipc-stack/provision/hyperv"
    log(f"creating VM {name}")
    powershell(hyperv / "New-IpcE2EVM.ps1", "-Name", name, "-InstallerIso", to_win(win_iso), "-VhdPath", to_win(vhd),
               "-ProcessorCount", str(cpus), "-MemoryGB", str(mem_gb), "-DiskGB", str(disk_gb))
    started = time.time()
    out = powershell(hyperv / "Complete-IpcE2EInstall.ps1", "-Name", name, "-InstallTimeoutMinutes", "90")
    ip = next(line.split("=", 1)[1].strip() for line in out.splitlines() if line.startswith("IPv4="))
    win_iso.unlink(missing_ok=True)   # C: is tight; the DVD is already ejected
    log(f"{name} installed and booted in {(time.time() - started) / 60:.1f} min at {ip}")
    return ip


@stage
def cloud_vm(state: dict) -> None:
    iso = Path(subprocess.run([str(HERE / "build-vm-media.sh"), "cloud-e2e"], check=True,
                              capture_output=True, text=True).stdout.strip().splitlines()[-1])
    state["cloud_ip"] = _vm(state, "cloud-e2e", iso, cpus=4, mem_gb=6, disk_gb=60)
    wait("cloud ssh", lambda: ssh(state["cloud_ip"], "cloud-init status --wait >/dev/null; echo ok").strip() == "ok",
         timeout=900, every=15)


@stage
def cloud_deploy(state: dict, *flags: str) -> None:
    env = dict(os.environ, E2E_CODE_ONLY="1" if "code" in flags else "0")
    subprocess.run([str(HERE / "cloud-vm" / "deploy.sh"), state["cloud_ip"]], check=True, env=env)


@stage
def cloud_admin(state: dict) -> None:
    """Platform-admin session and a 90-day installer credential, as Platform -> Hardware downloads it."""
    state["admin_token"] = mint_session(state, email=ADMIN_EMAIL, sub="e2e-platform-admin")
    cloud = Cloud(state)
    issued = cloud.post("/platform/hardware/installers", {"name": "e2e build machine"})
    path = PRIVATE / "cloud-e2e" / "cloud-enrollment.json"
    path.unlink(missing_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump({"cloud_url": cloud.base, "credential": issued["credential"]}, stream)
    log(f"installer credential saved to {path}")


@stage
def customer(state: dict, trial_minutes: str = "240") -> None:
    """Customer, physical site, site-agent, dated manual trial, owner invitation."""
    cloud = Cloud(state)
    name = f"E2E Mining {time.strftime('%m%d-%H%M')}"
    customer = cloud.post("/platform/customers", {"name": name})["customer"]
    state["customer_id"], state["customer_name"] = str(customer["id"]), name
    site = cloud.post(f"/customers/{state['customer_id']}/sites", {"name": "Prairie Pod Farm", "timezone": "America/Chicago"})
    state["site_id"] = str((site.get("site") or site)["id"])
    agent = cloud.post(f"/sites/{state['site_id']}/site-agents", {"name": "Prairie controller"})
    agent = agent.get("site_agent") or agent
    state["site_agent_id"], state["site_agent_slug"] = str(agent["id"]), agent.get("slug")
    expires = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + int(trial_minutes) * 60))
    cloud.call("PATCH", f"/customers/{state['customer_id']}/billing/service-access", {
        "mode": "manual", "remote_ui": True, "alerts": True, "optimizer": True,
        "optimizer_license_mode": "subscription", "expires_at": expires, "reason": "trial"})
    state["trial_expires_at"] = expires
    cloud.post(f"/customers/{state['customer_id']}/invites", {"email": CUSTOMER_EMAIL, "role": "owner", "expires_days": 7})
    log(f"customer {name} ({state['customer_id']}), site agent {state['site_agent_id']}, trial until {expires}")


@stage
def ipc_media(state: dict, source_tag: str, hostname: str = "ipc-e2e-mining-01") -> None:
    """Test-CA image + one unattended installer, through the same builder customer media uses."""
    ensure_proxy()
    e2e_tag = source_tag + "-ca"
    if not (CACHE / "images" / f"site-agent-{e2e_tag}.tar.gz").exists():
        subprocess.run([str(HERE / "ipc-image.sh"), source_tag, e2e_tag], check=True)
    media = CACHE / "media" / hostname
    if media.exists():
        subprocess.run(["rm", "-rf", str(media)], check=True)
    # A test copy of the private inputs: identical, except SSH stays reachable on
    # the Hyper-V switch (this workstation is not on the tailnet).
    private = PRIVATE / "cloud-e2e" / "private"
    (private / "console-passwords").mkdir(parents=True, exist_ok=True)
    for name in ("tailscale.env", "id_ed25519", "id_ed25519.pub"):
        (private / name).unlink(missing_ok=True)
        subprocess.run(["cp", "-p", str(PRIVATE / name), str(private / name)], check=True)
    seed = [l for l in (PRIVATE / "seed.env").read_text().splitlines() if not l.startswith("TAILSCALE_SSH_ONLY=")]
    (private / "seed.env").write_text("\n".join(seed + ["TAILSCALE_SSH_ONLY=0"]) + "\n")
    os.chmod(private / "seed.env", 0o600)
    env = dict(os.environ,
               IPC_E2E_PRIVATE_DIR=str(private),
               IPC_E2E_HOSTNAME=hostname, IPC_E2E_IMAGE_TAG=e2e_tag,
               IPC_E2E_IMAGE_DIR=str(CACHE / "images"), IPC_E2E_MEDIA_DIR=str(media),
               IPC_E2E_LOCAL_STACK="1", IPC_E2E_CONFIRM_ERASE="0",
               IPC_E2E_CLOUD_ENROLLMENT_CONFIG=str(PRIVATE / "cloud-e2e" / "cloud-enrollment.json"),
               IPC_E2E_LICENSE_PUBLIC_KEY=str(PRIVATE / "cloud-e2e" / "cloud.license.ed25519.pub"),
               SSL_CERT_FILE=str(CA_BUNDLE), https_proxy=PROXY,
               # Qualification only: skip the manual approval a customer box waits for.
               TS_PREAUTHORIZED="1")
    subprocess.run([str(Path.home() / "ipc-stack/provision/hyperv/build-media.sh")], check=True, env=env)
    state["ipc_hostname"], state["ipc_image_tag"] = hostname, e2e_tag
    state["ipc_iso"] = str(media / "ubuntu-ipc-autoinstall.iso")


@stage
def ipc_vm(state: dict) -> None:
    started = time.time()
    state["ipc_ip"] = _vm(state, state["ipc_hostname"], Path(state["ipc_iso"]), cpus=2, mem_gb=4, disk_gb=48)
    log("waiting for first boot to finish (ipc-firstboot.done)")
    wait("first boot", lambda: ssh(state["ipc_ip"], "test -e /var/lib/ipc-firstboot.done && echo done", check=False).strip() == "done",
         timeout=3600, every=20)
    state["ipc_install_minutes"] = round((time.time() - started) / 60, 1)
    log(f"IPC installed and first boot complete in {state['ipc_install_minutes']} min")


@stage
def plant_up(state: dict) -> None:
    """Ship the plant emulator to the IPC and run it beside the stack (host network, root for ports 161/502)."""
    root = Path.home() / "setpoint"
    tar = subprocess.run(["tar", "-C", str(root), "-czf", "-", "--exclude=__pycache__", "tools/sims/e2e_plant.py",
                          "tools/sims/fake_cgminer_fleet.py", "tools/sims/commissioning_sim.py", "tools/sims/modbus_sim.py"],
                         check=True, capture_output=True).stdout
    ipc_put(state, tar, "/opt/e2e/tools.tar.gz")
    ipc_put(state, (HERE / "plant" / "plant.json").read_bytes(), "/opt/e2e/plant.json")
    ipc_put(state, (HERE / "plant" / "e2e-plant-net.sh").read_bytes(), "/opt/e2e/e2e-plant-net.sh", "0755")
    ipc_sudo(state, "tar -C /opt/e2e -xzf /opt/e2e/tools.tar.gz && /opt/e2e/e2e-plant-net.sh")
    image = ipc_sudo(state, "docker inspect --format '{{.Config.Image}}' ipc-stack-site-agent-1").strip()
    ipc_sudo(state, "docker rm -f e2e-plant >/dev/null 2>&1; docker run -d --name e2e-plant --restart unless-stopped "
                    "--network host --user root -v /opt/e2e/tools:/app/tools:ro -v /opt/e2e/plant.json:/app/plant.json:ro "
                    f"-e PYTHONPATH=/app -w /app --entrypoint python {image} -m tools.sims.e2e_plant --config /app/plant.json")
    state["plant"] = wait("plant ready", lambda: plant(state), timeout=60, every=3)
    log(f"plant up: {len(state['plant']['drives'])} drives, {state['plant']['miners']['count']} miners, "
        f"{len(state['plant']['pdus'])} PDUs, ambient {state['plant']['ambient_c']} C")


@stage
def install_site(state: dict) -> None:
    """Platform admin assigns the enrolled box; the customer owner accepts it for the new site."""
    admin = Cloud(state)
    device = wait("controller in Platform -> Hardware", lambda: next(
        (d for d in admin.get("/platform/hardware") if d["name"] == state["ipc_hostname"] and d.get("online")), None),
        timeout=900, every=15)
    state["device_id"], state["ipc_tailscale_ip"] = device["id"], device["tailscale_ip"]
    log(f"enrolled: {device['name']} at {device['tailscale_ip']} ({device['status']})")
    admin.post(f"/platform/hardware/{device['id']}/assign", {"customer_id": state["customer_id"]})
    state["owner_token"] = mint_session(state, email=CUSTOMER_EMAIL, sub="e2e-customer-owner")
    owner = Cloud(state, "owner_token")
    options = owner.get(f"/site-agents/{state['site_agent_id']}/replacements")
    assert options["initial_setup_available"], options
    assert any(d["id"] == device["id"] for d in options["devices"]), options["devices"]
    request_id = str(uuid.uuid4())
    started = time.time()
    owner.post(f"/site-agents/{state['site_agent_id']}/replacements",
               {"request_id": request_id, "device_id": device["id"], "initial_setup": True})
    state["install_request_id"] = request_id
    done = wait("initial setup to finish", lambda: (owner.get(f"/site-agents/{state['site_agent_id']}/replacements")
                .get("operation") or {}).get("status") in {"active", "failed", "aborted"} and
                owner.get(f"/site-agents/{state['site_agent_id']}/replacements")["operation"], timeout=900, every=15)
    log(f"initial setup {done['status']} in {(time.time() - started) / 60:.1f} min")



@stage
def ipc_patch(state: dict) -> None:
    """Rebuild the controller's site-agent image with this working tree's site-agent/app and switch to it."""
    root = Path.home() / "setpoint"
    tar = subprocess.run(["tar", "-C", str(root / "site-agent"), "-czf", "-", "--exclude=__pycache__", "--exclude=*.pyc", "app"],
                         check=True, capture_output=True).stdout
    ipc_put(state, tar, "/opt/e2e/patch/app.tar.gz")
    current = ipc_sudo(state, "docker inspect --format '{{.Config.Image}}' ipc-stack-site-agent-1").strip()
    repo = current.rpartition(":")[0]
    base = f"{repo}:{state['ipc_image_tag']}"   # always patch the installed release
    n = state.get("ipc_patch_n", 0) + 1
    tag = f"{state['ipc_image_tag']}-p{n}"
    dockerfile = (f"FROM {base}\nUSER root\nRUN rm -rf /app/site-agent/app\n"
                  "ADD app.tar.gz /app/site-agent/\nRUN chown -R siteagent:siteagent /app/site-agent/app\nUSER siteagent\n")
    ipc_put(state, dockerfile.encode(), "/opt/e2e/patch/Dockerfile")
    ipc_sudo(state, f"cd /opt/e2e/patch && docker build -q -t {repo}:{tag} . >/dev/null", timeout=900)
    ipc_sudo(state, f"sed -i 's|^SITE_AGENT_VERSION=.*|SITE_AGENT_VERSION={tag}|' /opt/ipc-stack/.env && "
                    "cd /opt/ipc-stack && docker compose up -d site-agent >/dev/null 2>&1")
    wait("site-agent healthy", lambda: ssh(state["ipc_ip"], "curl -fsS -m 5 http://127.0.0.1:8000/livez >/dev/null && echo ok",
                                          check=False).strip() == "ok", timeout=300, every=5)
    state["ipc_patch_n"] = n
    log(f"controller now runs {tag}")



@stage
def history_import(state: dict) -> None:
    """Savings fast-forward: import a generated multi-week Basin history (separate zone) into the controller ledger."""
    root = Path.home() / "setpoint"
    hist = root / (CACHE / "run" / "history-dir").read_text().strip()
    shard = next((hist / "shards").iterdir())
    tar = subprocess.run(["tar", "-C", str(shard), "-czf", "-", "ledger.sqlite3", "ledger.sqlite3-wal", "ledger.sqlite3-shm",
                          "ledger-evidence"], capture_output=True).stdout
    ipc_put(state, tar, "/opt/e2e/history.tar.gz")
    tools = subprocess.run(["tar", "-C", str(root), "-czf", "-", "tools/sims/import_comparison_history.py"],
                           check=True, capture_output=True).stdout
    ipc_put(state, tools, "/opt/e2e/import-tool.tar.gz")
    image = ipc_sudo(state, "docker inspect --format '{{.Config.Image}}' ipc-stack-site-agent-1").strip()
    started = time.time()
    out = ipc_sudo(state, "set -e; rm -rf /opt/e2e/history && mkdir -p /opt/e2e/history && tar -C /opt/e2e/history -xzf /opt/e2e/history.tar.gz "
                          "&& tar -C /opt/e2e -xzf /opt/e2e/import-tool.tar.gz && chown -R 1000:1000 /opt/e2e/history; "
                          "cd /opt/ipc-stack && docker compose stop site-agent >/dev/null 2>&1; "
                          f"docker run --rm --user 1000:1000 -v /opt/site-agent/storage:/app/storage -v /opt/e2e/tools:/app/tools:ro "
                          f"-v /opt/e2e/history:/hist -e PYTHONPATH=/app/site-agent -w /app --entrypoint python {image} "
                          "/app/tools/sims/import_comparison_history.py --source /hist/ledger.sqlite3 --ledger /app/storage/ledger.sqlite3; "
                          "docker compose start site-agent >/dev/null 2>&1", timeout=1800)
    log(out.strip()[-1500:])
    wait("site-agent healthy", lambda: ssh(state["ipc_ip"], "curl -fsS -m 5 http://127.0.0.1:8000/livez >/dev/null && echo ok",
                                          check=False).strip() == "ok", timeout=300, every=5)
    state["history_imported_at"] = time.time()
    log(f"history imported in {(time.time() - started) / 60:.1f} min (site-agent was stopped meanwhile)")



def _ssh_shims(state: dict) -> Path:
    """ssh/scp that reach the test controller by hostname through the Windows relay (workstation is off-tailnet)."""
    shim = CACHE / "run" / "shim"
    shim.mkdir(parents=True, exist_ok=True)
    config = shim / "ssh_config"
    config.write_text(f"Host {state['ipc_hostname']}\n  HostName {state['ipc_ip']}\n  User toops\n"
                      f"  IdentityFile {PRIVATE / 'id_ed25519'}\n  ProxyCommand {RELAY}\n"
                      "  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n")
    for tool in ("ssh", "scp"):
        (shim / tool).write_text(f"#!/bin/sh\nexec /usr/bin/{tool} -F {config} \"$@\"\n")
        (shim / tool).chmod(0o755)
    return shim


@stage
def offboard(state: dict) -> None:
    """Unconverted trial: ipc-stack/provision/offboard-controller.sh, then app.offboard on the Cloud."""
    private = PRIVATE / "cloud-e2e" / "private"
    shim = _ssh_shims(state)
    env = dict(os.environ, PATH=f"{shim}:{os.environ['PATH']}", IPC_E2E_PRIVATE_DIR=str(private))
    started = time.time()
    result = subprocess.run(["uv", "run", "--quiet", "--with", "pexpect", "python", str(HERE / "offboard_driver.py"),
                             state["ipc_hostname"], str(private / "console-passwords" / state["ipc_hostname"])],
                            env=env, capture_output=True, text=True, timeout=1200)
    (CACHE / "run" / "offboard-controller.log").write_text(result.stdout + result.stderr)
    log(f"offboard-controller.sh exit {result.returncode} in {(time.time() - started) / 60:.1f} min")
    log(result.stdout[-1800:])
    name = shlex.quote(state["customer_name"])
    preview = ssh(state["cloud_ip"], f"{cloud_compose(state)} exec -T api python -m app.offboard {name}", check=False)
    log("app.offboard preview:\n" + preview[-1500:])
    applied = ssh(state["cloud_ip"], f"{cloud_compose(state)} exec -T api python -m app.offboard {name} --yes", check=False)
    log("app.offboard --yes:\n" + applied[-1500:])
    state["offboarded_at"] = time.time()



@stage
def rehydrate(state: dict) -> None:
    """Returning customer: assign the new box, then Replace hardware with the 'Trial ended' backup."""
    admin, owner = Cloud(state), Cloud(state, "owner_token")
    device = wait("new controller in Platform -> Hardware", lambda: next(
        (d for d in admin.get("/platform/hardware") if d["name"] == state["ipc_hostname"] and d.get("online")), None),
        timeout=900, every=15)
    state["device_id"], state["ipc_tailscale_ip"] = device["id"], device["tailscale_ip"]
    admin.post(f"/platform/hardware/{device['id']}/assign", {"customer_id": state["customer_id"]})
    options = owner.get(f"/site-agents/{state['site_agent_id']}/replacements")
    named = [b for b in options.get("named_backups") or [] if str(b.get("name", "")).startswith("Trial ended")]
    log(f"replacement options: initial_setup={options.get('initial_setup_available')} spares={[d['name'] for d in options['devices']]} "
        f"named={[b['name'] for b in named]} expected_ipc={options.get('expected_ipc_id')}")
    if not named:
        raise RuntimeError("no 'Trial ended' backup offered")
    request_id = str(uuid.uuid4())
    started = time.time()
    owner.post(f"/site-agents/{state['site_agent_id']}/replacements", {
        "request_id": request_id, "device_id": device["id"], "expected_ipc_id": options.get("expected_ipc_id"),
        "old_disconnected": True, "recovery_id": named[0]["recovery_id"], "allow_historical_backup": True})
    done = wait("replacement to finish", lambda: (owner.get(f"/site-agents/{state['site_agent_id']}/replacements")
                .get("operation") or {}).get("status") in {"active", "failed", "aborted"} and
                owner.get(f"/site-agents/{state['site_agent_id']}/replacements")["operation"], timeout=1200, every=15)
    state["rehydrate_request_id"] = request_id
    log(f"replacement {done['status']} in {(time.time() - started) / 60:.1f} min")


if __name__ == "__main__":
    main()
