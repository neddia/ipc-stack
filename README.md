# IPC Stack (public)

Minimal, public bootstrap repo for IPC installs. It pulls a prebuilt
`site-agent` image from the Toops release mirror and runs local InfluxDB +
Telegraf + site-agent. State is stored on the host so rollbacks are safe.

The release mirror is a read-only cache of the private GHCR image, reachable
only over the tailnet as `release-mirror:5000`. Devices pull anonymously and
keep no registry login; tailnet membership is what grants access to releases.

## Layout

- `compose.yml` — InfluxDB + Telegraf + site-agent (image-based).
- `.env.example` — deployment settings (copy to `.env`).
- `install.sh` — one-time install + seed storage from the pinned image.
- `update.sh` — pin the site-agent image to a release (optionally by digest),
  snapshot site state, restart, health-gate with auto-rollback (restoring the
  snapshot) to the previous release, prune old images.
- `provision/` — zero-touch OS install (Ubuntu autoinstall + first-boot
  bring-up); see `provision/README.md`.
- `scripts/sync-defaults.sh` — extract the bundled config example and prepare persistent site-profile storage.
- `scripts/toops-support.sh` — installed as `toops-support`; lets the site
  owner switch Toops SSH access off and on.
- `scripts/` — helpers (secrets, hardening, SSH lockdown).

## Quick start (new IPC)

For the normal one-ISO blank-machine workflow, see
[`provision/README.md`](provision/README.md). The lower-level manual install
remains available for repair and development:

```bash
git clone https://github.com/<you>/ipc-stack.git
cd ipc-stack

# Join the tailnet first so the release mirror is reachable:
TS_AUTHKEY="<authkey>" TS_TAGS="tag:ipc" sudo ./install.sh
```

Only an image still pointing at `ghcr.io` asks for `GHCR_USER`/`GHCR_TOKEN`;
that path exists for boxes not yet moved to the mirror.

Without `TS_AUTHKEY`, `tailscale up` prints a login URL instead. If the tailnet
requires device approval, install waits until an operator approves the device.

If you want to lock SSH to Tailscale only:

```bash
sudo ./scripts/lockdown-ssh.sh
```

## Host port binding

By default, the site-agent UI binds to `0.0.0.0:8000` so operators can reach it
on the LAN. InfluxDB binds to `127.0.0.1` only. Equipment communication runs inside site-agent.

For intentional debugging or tighter deployment, override bind hosts in `.env`:

```bash
# Default: LAN/Tailnet-accessible local UI
SITE_AGENT_BIND_HOST=0.0.0.0

# Tighter: Tailscale-only local UI
SITE_AGENT_BIND_HOST=<tailscale-ip>
```

Prefer leaving InfluxDB on `127.0.0.1`; expose it only briefly
for debugging.

## Update / rollback

```bash
# Tag plus the digest from the publish workflow's run summary:
sudo ./update.sh sha-3935e3f@sha256:<digest>
# rollback by hand
sudo ./update.sh sha-1a2b3c4@sha256:<its digest>
```

With a digest, the pulled image must match it or nothing changes. Before
switching to a different release, `update.sh` snapshots site config, profiles,
alert policy and the SQLite databases into `storage/update-snapshots/` (the
newest two are kept; `storage/ipc` is never included). If the health check
fails it stops site-agent, restores that snapshot, and starts the previous
release. A failed pull, digest check or snapshot leaves the device on its
current release.

The health check waits up to 5 minutes for a slow start but fails at once on a
crash loop. It records the running release's startup errors first and fails
the new one only on errors it adds, so a dead drive at the site is not blamed
on the update. After passing it watches site-agent for 3 more minutes
(`IPC_UPDATE_SOAK_S`) before old images are pruned, and fails if the new
release reaches fewer drives than the old one did (more than a quarter lost,
or any on sites with up to three drives, confirmed over three checks).

Updates pull through the release mirror. On a box whose `.env` still names
`ghcr.io`, switch `SITE_AGENT_IMAGE` to `release-mirror:5000/neddia/site-agent`
and rerun `update.sh` with the current version; it trusts the mirror and
deletes the stored GHCR login.

## Support access

Customers have no OS account on the controller. Toops shell access is standard
OpenSSH with the operator key, reachable only over the tailnet.
`toops-support` is the host switch for it:

```bash
sudo toops-support off     # block Toops SSH logins and end open sessions
sudo toops-support on      # allow them again
sudo toops-support status  # current setting and recent Toops logins
```

It is meant to be driven by a site-admin toggle in the local dashboard (not
built yet). Run from an SSH session, `off` cannot be undone remotely; turning
it back on then needs the console. It covers SSH only; the Cloud portal keeps
working through the site-agent API.

## Dev mode (bind-mount setpoint)

For local development without rebuilding images, use the dev override which
bind-mounts the `setpoint` repo into the running containers:

```bash
cd ipc-stack
# default assumes ../setpoint exists
./dev-up.sh
```

You can also set `SETPOINT_DIR` if your repo lives elsewhere:

```bash
SETPOINT_DIR=/home/you/setpoint ./dev-up.sh
```

`dev-up.sh` will prefer `.env.dev` if present; otherwise it uses `.env`.


For dev, secrets default to `../ipc-secrets` (outside the repo) via `.env.dev`.

By default, `dev-up.sh` starts the Tailwind watcher so template class changes are
compiled into `site-agent/app/static/tailwind.css`. Optional toggles:

```bash
# include sim container(s)
ENABLE_SIM=1 ./dev-up.sh .env.dev

# disable tailwind watcher
ENABLE_TAILWIND=0 ./dev-up.sh .env.dev

# force image rebuild
BUILD_IMAGES=1 ./dev-up.sh .env.dev
```

With `ENABLE_SIM=1`, the dev override brings up both the multi-unit Modbus VFD
simulator and the fake cgminer fleet used for dashboard/optimizer testing.

## Notes

- Secrets are created in `./.secrets/` (gitignored).
- Storage lives at `/opt/site-agent/storage` by default (bind mount).
- The image tag is controlled by `SITE_AGENT_VERSION` in `.env`.
- `install.sh` initializes missing runtime config from the install-safe empty
  default and refreshes `site-config.example.yml` as a commissioning reference.
  Built-in profiles stay immutable inside the site-agent image; commissioned
  profiles live in persistent `storage/site-profiles/`.

## Check deployment changes locally

Run `python3 -m unittest discover -s tests -v`. The release-workflow tests exercise
installation, image pinning/pruning, failed-update rollback and media staging with
temporary files and fake host/Docker commands. They do not install software on the
host or boot an ISO. Use the [VM qualification guide](provision/hyperv/README.md)
for a full first-boot and controller-replacement check before shipping an image.
