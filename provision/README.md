# IPC provisioning and commissioning

This is the canonical runbook for turning a blank x86 machine into a paired
IPC. Provisioning and customer commissioning are deliberately separate:

1. Build and flash one unattended installer for a specific IPC.
2. Install an unpaired appliance and let first boot bring up the stack.
3. Create the customer and site in Toops Cloud, then pair the appliance.

No customer login or Cloud administrator credential is stored on the IPC.

The supported workflow currently creates one self-contained ISO per IPC. It
does not require a second `CIDATA` drive or partition. A reusable factory USB
with a replaceable per-device `CIDATA` partition could reduce repeated ISO
builds later, but that workflow is not implemented or qualified yet.

## Files and directories

On the operator workstation:

| Path | Purpose |
| --- | --- |
| `~/ipc-stack` | Public deployment, provisioning, install, and update code |
| `~/.config/toops-e2e/` | Private GHCR seed, Tailscale OAuth client, SSH key, and console password |
| `~/.cache/toops-e2e/` | Ubuntu ISO, build cache, and generated appliance ISOs |

On an installed IPC:

| Path | Purpose |
| --- | --- |
| `/opt/ipc-stack/` | Deployment checkout, Compose files, and `.env` |
| `/opt/site-agent/storage/` | Site config, state databases, identity, and commissioned profiles |
| `/opt/site-agent/.secrets/` | Generated IPC, gateway, and Influx credentials |
| `/root/.docker/config.json` | Read-only GHCR login retained for image updates |
| `/var/lib/ipc-firstboot.done` | Marker written only after first boot succeeds |

InfluxDB data and metadata live in named Docker volumes.

## Prepare the operator workstation once

Private inputs stay outside the public repository:

```bash
cd ~/ipc-stack
mkdir -p ~/.config/toops-e2e ~/.cache/toops-e2e
chmod 700 ~/.config/toops-e2e ~/.cache/toops-e2e
install -m 600 provision/seed.env.example ~/.config/toops-e2e/seed.env
install -m 600 provision/tailscale.env.example ~/.config/toops-e2e/tailscale.env
```

Edit `~/.config/toops-e2e/seed.env` with:

- a GHCR classic PAT with `read:packages` only;
- immutable `SITE_AGENT_VERSION` and `GATEWAYD_VERSION` tags;
- the production Cloud URLs.

Create one Tailscale OAuth client with the `auth_keys` write scope restricted
to `tag:ipc`. Put its client ID and secret in
`~/.config/toops-e2e/tailscale.env`. The long-lived OAuth credential never
leaves the workstation. Each build uses it to mint one tagged,
pre-authorized, non-ephemeral, single-use auth key and embeds only that key in
the installer. A populated `TS_AUTHKEY` in `seed.env` remains a manual
fallback.

The first build creates an operator SSH key and physical-console password in
the same private directory. They are currently reused across generated IPCs,
so back up and protect this directory. Generated appliance runtime secrets
are separate and are created on each IPC under `/opt/site-agent/.secrets`.

Place the pinned Ubuntu ISO at:

```text
~/.cache/toops-e2e/ubuntu-24.04.4-live-server-amd64.iso
```

Set `UBUNTU_ISO` and `UBUNTU_ISO_SHA256` to use a different Ubuntu image.

## Publish the software before a production build

A production installer pulls two things rather than embedding the local
working trees:

- `ipc-stack` from its public GitHub repository;
- the private `site-agent` and `gatewayd` images from GHCR.

Commit and push the intended `ipc-stack` revision, and publish the matching
Setpoint images before building. Use the immutable `sha-<short-commit>` image
tag produced by the Setpoint publishing workflow. Deploy the compatible Cloud
revision before commissioning the appliance.

`IPC_E2E_LOCAL_STACK=1` exists for local qualification and embeds the current
`ipc-stack` tree. It is not the normal production path.

## Build one IPC installer

Use a unique hostname and output directory for every appliance. Override both
container versions with one known-good immutable tag:

```bash
cd ~/ipc-stack
device=ipc-001
tag=sha-3935e3f

IPC_E2E_HOSTNAME="$device" \
IPC_E2E_IMAGE_TAG="$tag" \
IPC_E2E_MEDIA_DIR="$HOME/.cache/toops-e2e/media/$device" \
IPC_E2E_LOCAL_STACK=0 \
./provision/hyperv/build-media.sh
```

The output is one self-contained unattended installer:

```text
~/.cache/toops-e2e/media/ipc-001/ubuntu-ipc-autoinstall.iso
```

The generated ISO has mode `0600`. It contains the shared read-only GHCR PAT
and one disposable Tailscale auth key. It does not contain the Tailscale OAuth
secret or operator SSH private key.

## Flash and install from USB

Open the output directory in Windows from WSL:

```bash
explorer.exe "$(wslpath -w "$HOME/.cache/toops-e2e/media/$device")"
```

Then:

1. Use Balena Etcher or Rufus to write the ISO to an 8 GB or larger USB drive.
   Raw/DD mode is the safest choice when Rufus asks.
2. Connect the target IPC to Ethernet.
3. Boot the target from the USB in UEFI mode.
4. Let Ubuntu autoinstall run. It wipes the target's internal disk and powers
   the machine off when installation finishes.
5. Remove the USB and boot from the internal disk.

First boot installs Docker and Tailscale, joins the tailnet, clones the
published deployment stack, logs into GHCR, pulls the pinned private images,
generates runtime secrets, starts InfluxDB, site-agent, gatewayd, and
Telegraf, and runs the stack health check. It then restricts SSH to the
Tailscale interface, shreds the copied seed, and writes the completion marker.
If any required step fails, the marker is not written and the unit retries on
the next boot.

## Verify and commission the customer

Confirm the IPC appears in Tailscale. Remote shell access uses standard
OpenSSH over the tailnet:

```bash
ssh -i ~/.config/toops-e2e/id_ed25519 toops@ipc-001
```

Log into Toops Cloud with the configured platform-admin account:

1. Open **Platform** and create the customer.
2. Select that customer, open **Site-Agents**, and create its site and
   site-agent.
3. Click **Pair Agent** and copy the generated code.
4. Open the IPC edge settings at `http://<tailscale-ip>:8000` and enter the
   code.
5. Confirm the signed Cloud check-in succeeds.
6. Open **Users** and invite the customer's owner email.

Supabase sends the invitation and owns the login credentials. When the user
accepts or signs in, Toops Cloud creates its local user row and attaches the
invited customer membership. Customer, site, and site-agent names can be
changed later without changing their stable identities or re-pairing.

## Access and credential handling

Tailscale is the private network transport. Standard Ubuntu OpenSSH remains
the login service, with the operator key only. Password SSH is disabled and
the firewall restricts port 22 to the Tailscale interface. The console
password in `~/.config/toops-e2e/console-password` is for physical console and
`sudo` recovery.

Docker retains the read-only GHCR login so future image updates can pull
private images. Because the generated ISO and flashed USB contain that
credential, treat both as secrets. After the IPC is healthy and paired, erase
the USB and delete its generated ISO:

```bash
rm "$HOME/.cache/toops-e2e/media/$device/ubuntu-ipc-autoinstall.iso"
```

## Troubleshooting

- First-boot status: `systemctl status ipc-firstboot`
- First-boot logs: `journalctl -u ipc-firstboot -b`
- Stack health check: `/opt/ipc-stack/scripts/check-health.sh`
- Service state: `cd /opt/ipc-stack && sudo docker compose ps`
- The first-boot unit retries on each boot until every required step succeeds.
