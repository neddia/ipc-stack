# IPC Stack (public)

Minimal, public bootstrap repo for IPC installs. It pulls a prebuilt
`site-agent` image from GHCR and runs local Influx + site-agent. State is
stored on the host so rollbacks are safe.

## Layout

- `compose.yml` — Influx + site-agent (image-based).
- `.env.example` — deployment settings (copy to `.env`).
- `install.sh` — one-time install + seed storage.
- `update.sh` — pull a new image tag and restart.
- `scripts/` — helpers (secrets, hardening, SSH lockdown).
- `storage/seed/site-config.yml` — example config template.

## Quick start (new IPC)

```bash
git clone https://github.com/<you>/ipc-stack.git
cd ipc-stack

# If your image is private on GHCR, pass a read:packages token:
GHCR_USER="<user>" GHCR_TOKEN="<token>" sudo ./install.sh
```

If you want non-interactive Tailscale enrollment:

```bash
TS_AUTHKEY="<authkey>" TS_TAGS="tag:ipc" sudo ./install.sh
```

If you want to lock SSH to Tailscale only:

```bash
sudo ./scripts/lockdown-ssh.sh
```

## Update / rollback

```bash
sudo ./update.sh 1.2.3
# rollback
sudo ./update.sh 1.2.2
```

If the image is private, pass GHCR creds:

```bash
GHCR_USER="<user>" GHCR_TOKEN="<token>" sudo ./update.sh 1.2.3
```

## Notes

- Secrets are created in `./.secrets/` (gitignored).
- Storage lives at `/opt/site-agent/storage` by default (bind mount).
- The image tag is controlled by `SITE_AGENT_VERSION` in `.env`.
