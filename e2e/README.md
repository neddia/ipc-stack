# Basin end-to-end run (development only)

Disposable Hyper-V VMs exercise the real install, commissioning, licensing,
billing and offboarding paths against a **test Cloud**, never production.
Nothing here ships in an appliance image.

```
WSL (driver, browser) ──connect-proxy──▶ Windows ──▶ Hyper-V Default Switch
                                                     ├─ cloud-e2e  (toops-cloud, Caddy test CA, stripe listen, tailnet tag:gateway)
                                                     └─ ipc-e2e-*  (installer ISO, site-agent, e2e plant emulator)
```

## Pieces

| File | What it does |
| --- | --- |
| `run.py` | Stage runner; state in `~/.cache/toops-e2e/run/state.json` (`run.py state`, `run.py findings`) |
| `e2e.py` | Helpers: SSH through the Windows relay, Cloud API client, edge/plant calls, session minting |
| `build-vm-media.sh`, `cloud-vm/` | Plain Ubuntu autoinstall for the Cloud VM; `deploy.sh` ships the local toops-cloud tree |
| `ipc-image.sh` | Derives a site-agent image that trusts the test Cloud CA (appended to certifi; the Cloud clients ignore `SSL_CERT_FILE`) |
| `connect-proxy.py`, `win-relay.py` | WSL cannot route to the Default Switch and has no root for NAT; Windows can. CONNECT proxy for HTTPS/browser, relay as SSH `ProxyCommand` |
| `ui-driver.cjs` | One persistent Chromium (shared Playwright in `~/codex-tools/browser-checks`) driven over `127.0.0.1:9333` for UI walkthroughs |
| `plant/` | Plant config and the "equipment LAN" dummy interface; the emulator is `setpoint/tools/sims/e2e_plant.py` |

The plant emulates hardware Basin does not ship profiles for: two ABB ACS580
drives (Modbus TCP, ABB Drives profile), 24 Whatsminer M60S (btminer API v2)
and two Raritan PX3 PDUs (SNMP PDU2-MIB), coupled through the fleet sim's
thermal model so drive speed moves miner fans, temperatures and PDU power.
Its control API (`127.0.0.1:8099` on the IPC) sets ambient and injects faults.

## Prerequisites

- Hyper-V access from WSL (`powershell.exe Get-VM` works), Windows Python at
  `/mnt/c/msys64/ucrt64/bin/python.exe` (override `E2E_WIN_PYTHON`).
- `~/.config/toops-e2e/` as for real installers (seed, Tailscale OAuth client,
  operator key). The test copies them to `cloud-e2e/private/` with
  `TAILSCALE_SSH_ONLY=0`, because this workstation is not on the tailnet.
- The Cloud VM joins the tailnet as `tag:gateway` (Cloud must reach
  `/hardware/identity` on the box's tailnet address before assignment): put a
  pre-approved auth key in `~/.config/toops-e2e/cloud-gateway.authkey`, or run
  `sudo tailscale up --advertise-tags=tag:gateway` on the VM and approve the login.
  **Remove `cloud-e2e` from the tailnet when finished**: `tag:gateway` reaches
  port 8000 on every `tag:ipc` node.
- RAM: about 10 GB free on Windows for both VMs. Stop Docker Desktop's dev
  stacks first on a 32 GB machine. Disk: about 30 GB free on C:.

## Stage order

```bash
cd ~/ipc-stack/e2e
R="uv run --project ~/setpoint python run.py"
$R cloud-vm                 # ~25 min: build ISO, install, boot
$R cloud-deploy             # build api, fresh DB, migrations, stripe listen, Caddy test CA
$R cloud-admin              # platform-admin session + installer credential
$R customer 480             # customer/site/site-agent, 8 h trial, owner invite
$R ipc-media <image-tag>    # test-CA image + installer ISO (enrollment ticket, Tailscale key)
$R ipc-vm                   # ~10 min install + first boot
$R install-site             # assign hardware, customer accepts for the new site
$R plant-up                 # emulator on the IPC
# commissioning through the edge UI, savings, trial lapse, offboarding,
# rehydration and subscription stages follow; see run.py.
$R cloud-deploy code        # after editing toops-cloud: ship api/app, migrate, restart
```

Findings recorded during a run: `$R findings`. The write-up of the first run
is `setpoint/docs/verification/e2e-basin-lifecycle.md`.
