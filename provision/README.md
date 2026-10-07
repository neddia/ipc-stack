# IPC provisioning and commissioning

This is the canonical runbook for turning a blank x86 machine into a paired
IPC. Provisioning and customer commissioning are deliberately separate:

1. Build and flash one unattended installer for a specific IPC.
2. Install an unpaired appliance and let first boot bring up the stack.
3. Create the customer and site in Toops Cloud, then pair the appliance.

No Cloud administrator credential or registry credential is stored on the
IPC, and the customer has no OS login on it.

The supported workflow currently creates one self-contained ISO per IPC. It
does not require a second `CIDATA` drive or partition. A reusable factory USB
with a replaceable per-device `CIDATA` partition could reduce repeated ISO
builds later, but that workflow is not implemented or qualified yet.

## Files and directories

On the operator workstation:

| Path | Purpose |
| --- | --- |
| `~/ipc-stack` | Public deployment, provisioning, install, and update code |
| `~/.config/toops-e2e/` | Private seed, Tailscale OAuth client, SSH key, and per-device console passwords |
| `~/.cache/toops-e2e/` | Ubuntu ISO, build cache, and generated appliance ISOs |

On an installed IPC:

| Path | Purpose |
| --- | --- |
| `/opt/ipc-stack/` | Deployment checkout, Compose files, and `.env` |
| `/opt/site-agent/storage/` | Site config, state databases, identity, and commissioned profiles |
| `/opt/site-agent/.secrets/` | Generated IPC, gateway, and Influx credentials |
| `/etc/docker/daemon.json` | Trusts the tailnet-only release mirror; no registry login is kept |
| `/usr/local/sbin/toops-support` | Host switch for Toops SSH access (for a future dashboard toggle) |
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

- an immutable `SITE_AGENT_VERSION` tag;
- the production Cloud URLs.

Do not put registry credentials in it. Devices pull through the release mirror
(`docs/release-mirror.md` in Toops Cloud), and the builder drops any `GHCR_*`
values it finds.

Create one Tailscale OAuth client with the `auth_keys` write scope restricted
to `tag:ipc`. Put its client ID and secret in
`~/.config/toops-e2e/tailscale.env`. The long-lived OAuth credential never
leaves the workstation. Each build uses it to mint one tagged,
pre-authorized, non-ephemeral, single-use auth key and embeds only that key in
the installer. A populated `TS_AUTHKEY` in `seed.env` remains a manual
fallback.

Minted keys are not pre-approved and expire after seven days
(`TS_AUTHKEY_EXPIRY_SECONDS` overrides). With "Manually approve new devices"
enabled in the Tailscale admin console, a box that uses one joins but waits,
showing a notice on its console, until you approve it. That approval is the
gate for customer hardware: only approved devices can reach the release
mirror. Tailnet Lock is not enabled.

The first build creates an operator SSH key in the same private directory; it
is reused across IPCs. Each build also creates, or reuses when rebuilding the
same hostname, a console/`sudo` password for that device only, at
`console-passwords/<hostname>`. IPCs built before this used the shared
`console-password` file, which is still needed for them. Back up and protect
this directory. Generated appliance runtime secrets
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
- the private `site-agent` image through the tailnet-only release mirror,
  after the device has joined the tailnet.

Commit and push the intended `ipc-stack` revision, and publish the matching
Setpoint image before building. Use the immutable `sha-<short-commit>` image
tag produced by the Setpoint publishing workflow. Deploy the compatible Cloud
revision before commissioning the appliance.

`IPC_E2E_LOCAL_STACK=1` exists for local qualification and embeds the current
`ipc-stack` tree. It is not the normal production path.

## Build one IPC installer

For a customer, use the wrapper. It names the device after the customer
(`ipc-acme-mining-01`, counting up per customer), builds the ISO, and prints
the onboarding checklist, including the trial and subscription steps in Cloud:

```bash
IPC_E2E_IMAGE_TAG=sha-3935e3f ./provision/new-customer-installer.sh "Acme Mining"
```

To build one directly, use a unique hostname and output directory for every
appliance. Override both container versions with one known-good immutable tag:

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

The generated ISO has mode `0600`. Its only credential is one single-use
Tailscale auth key that needs your approval to become useful. It contains no
registry credential, Tailscale OAuth secret, or operator SSH private key.


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
4. At "Continue with autoinstall?" type `yes`. This is the only question: the
   installer then erases the largest internal disk, uses all of it, and powers
   the machine off when installation finishes. Remove any other disk that must
   be kept before booting the USB.
5. Remove the USB and boot from the internal disk.

First boot installs Docker and Tailscale, joins the tailnet (waiting for your
approval if required), clones the published deployment stack, trusts the
release mirror, pulls the pinned image through it,
generates runtime secrets, starts InfluxDB, site-agent, and
Telegraf, and runs the stack health check. It then restricts SSH to the
Tailscale interface, shreds the copied seed, and writes the completion marker.
If any required step fails, the marker is not written and the unit retries on
the next boot.

## Verify and commission the customer

Confirm the IPC appears in Tailscale, and approve it there if device approval
is on. Remote shell access uses standard OpenSSH over the tailnet:

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

## When a trial ends

The signed optimizer license says what the controller does once it lapses:

- **Commissioning settled** (Cloud Billing: "Customer may start the subscription" ticked):
  when the subscription later ends, each zone keeps following Basin's learned map
  for the current outdoor temperature and load, with no learning or tests and full
  speed where nothing was mapped. Nothing to run.
- **Trial not converted**: Basin stops and the fans go to full speed. Then:
  1. Put the drives back on the customer's own control. This depends on the site
     (remote/local switch, run and speed source, sometimes more) and is done by hand.
  2. `provision/offboard-controller.sh <hostname>` uploads a final recovery backup to
     Cloud, clears Basin from the box, takes it off the tailnet and powers it off. It
     needs Toops support access and the controller's console password. Removing the
     tailnet machine needs an OAuth client with `devices:core`; otherwise remove it
     in the admin console.
  3. On the Cloud VM: `docker compose exec api python -m app.offboard "Customer name"`
     shows what changes; add `--yes` to end access, unpair the site and retire the
     hardware. The customer's data stays for a later purchase, and each site's last
     recovery backup is named "Trial ended <date>" so pruning never removes it.

If the customer comes back, give them access again (trial grant or "may start the
subscription"), install the ISO on the controller as for a new box, and assign it
to the customer in Platform → Hardware. Then open the site, choose **Replace
hardware**, select the "Trial ended <date>" backup and the controller. It restores
the configuration, site profiles, learned maps, comparison setup and training
evidence, and miner identities; issued statements never left Cloud. Check the
drives' run and speed source again before Basin takes control.

## Access and credential handling

Tailscale is the private network transport. Standard Ubuntu OpenSSH remains
the login service, with the operator key only. Password SSH is disabled and
the firewall restricts port 22 to the Tailscale interface. The console
password in `~/.config/toops-e2e/console-passwords/<hostname>` is for the
physical console and `sudo` on that device.

The customer has no OS account. They control Toops access with the **Toops
Support Access** switch in the dashboard's Settings, or `sudo toops-support
off|on` at the console. Off blocks Toops SSH, drops tailnet access to the
dashboard except through the Toops Cloud gateway (so the customer's own Cloud
remote access keeps working), and makes the Cloud proxy refuse platform-admin
sessions. Updates that need SSH wait until it is back on. The dashboard shows
the setting, who last changed it, and recent Toops logins. A root path unit
(`ipc-support-access.path`/`.timer`) applies the dashboard's choice. The
switch ships disabled: it appears, and the host units run, only on a device
whose `.env` has `SUPPORT_ACCESS_TOGGLE=1`. Until then `sudo toops-support
off|on` at the console is the only control.

No registry login is kept. Updates pull through the release mirror, and
removing the device from the tailnet stops them. The ISO's Tailscale key is
single use; once the IPC is healthy, erase the USB and delete its ISO:

```bash
rm "$HOME/.cache/toops-e2e/media/$device/ubuntu-ipc-autoinstall.iso"
```

## Troubleshooting

- First-boot status: `systemctl status ipc-firstboot`
- First-boot logs: `journalctl -u ipc-firstboot -b`
- Stack health check: `/opt/ipc-stack/scripts/check-health.sh`
- Container logs live in the persistent journal (about six weeks, capped at
  1 GB) and survive updates, rollbacks and reboots:
  `journalctl -t ipc-stack-site-agent-1 --since "2026-09-28 15:00" --until "15:30"`
  (`docker logs` still works for the current container). Set up by
  `scripts/configure-logging.sh` on install and on every update.
- Service state: `cd /opt/ipc-stack && sudo docker compose ps`
- The first-boot unit retries on each boot until every required step succeeds.
