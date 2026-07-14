# IPC provisioning (zero-touch OS install)

Turns a blank machine into a healthy IPC with no keyboard input:
Ubuntu Server autoinstall lays down the OS with only the operator account,
then a first-boot unit joins Tailscale, installs the stack via `install.sh`,
locks SSH to the tailnet, and health-checks — all driven by a per-site
`seed.env`.

Workflow: flash → boot in the shop → wait for green in the tailnet →
ship the box. On site it is power + ethernet only.

## What's here

- `autoinstall/user-data` — autoinstall template. Fill the three per-machine
  fields (hostname, crypted console password, operator SSH key).
- `autoinstall/meta-data` — required empty file (NoCloud datasource).
- `seed.env.example` — per-site secrets consumed once on first boot
  (Tailscale auth key, GHCR token, version pins).
- `firstboot/` — systemd oneshot + script installed by the autoinstall
  late-commands. Retries on next boot until it succeeds, shreds the seed,
  then marks itself done (`/var/lib/ipc-firstboot.done`).

## Preparing an install USB

1. Write a stock Ubuntu Server LTS ISO to USB stick #1 (e.g. `dd` or
   balenaEtcher).
2. Prepare a second small volume labeled `CIDATA` (FAT32) — a second USB
   stick or a second partition on the same stick:

   ```bash
   # example: /dev/sdX2 is a small FAT32 partition
   sudo mkfs.vfat -n CIDATA /dev/sdX2
   mount /dev/sdX2 /mnt
   cp provision/autoinstall/user-data /mnt/user-data
   cp provision/autoinstall/meta-data /mnt/meta-data
   cp seed.env /mnt/seed.env        # from provision/seed.env.example
   umount /mnt
   ```

3. Edit `user-data` on the CIDATA volume for this machine:
   - `identity.hostname`: `ipc-<site>`
   - `identity.password`: `mkpasswd -m sha-512` output (cleartext goes in
     your password manager — it is the physical-console password only)
   - `ssh.authorized-keys`: your operator pubkey

4. Boot the target from USB #1 with the CIDATA volume attached. At the GRUB
   menu, edit the kernel line and append `autoinstall` for a fully
   unattended run (otherwise the installer asks one yes/no confirmation
   before wiping the disk).

The installer wipes the disk, installs Ubuntu with the operator account
(key-only SSH), clones this repo to `/opt/ipc-stack`, copies `seed.env` in
root-only, and enables the first-boot unit. On the next boot the machine
appears in your tailnet and `check-health.sh` gates success.

## Per-site checklist

- [ ] Generate console password → password manager; hash into `user-data`
- [ ] Create a single-use, pre-authorized Tailscale auth key (`tag:ipc`)
- [ ] Fine-grained GHCR token (`read:packages` only)
- [ ] Pin `SITE_AGENT_VERSION` / `GATEWAYD_VERSION` in `seed.env`
- [ ] Flash, boot in shop, verify: device green in Tailscale admin +
      `http://<tailnet-ip>:8000` responds
- [ ] After first boot the seed is shredded; the auth key + GHCR token
      should be treated as consumed

## Troubleshooting

- Progress/logs: `journalctl -u ipc-firstboot -b`
- The unit retries on every boot until it succeeds; to re-run manually:
  `sudo systemctl start ipc-firstboot`
- To force a full re-provision: `sudo rm /var/lib/ipc-firstboot.done`
  (needs a fresh `seed.env` in `/opt/ipc-stack/` if secrets are required).
