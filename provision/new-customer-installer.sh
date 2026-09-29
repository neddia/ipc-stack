#!/usr/bin/env bash
# Build the installer for one customer controller and print the onboarding checklist.
#
#   provision/new-customer-installer.sh "Acme Mining" [unit-number]
#
# The hostname names the customer (ipc-acme-mining-01) so the device is
# recognisable in Tailscale approval, Cloud hardware inventory and on the site
# LAN. Unit numbers count up per customer from the builds already on this
# workstation. The ISO holds a single-use Tailscale key and enrollment ticket:
# share it only through a private, expiring link and delete it once installed.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_DIR="${IPC_E2E_PRIVATE_DIR:-$HOME/.config/toops-e2e}"
CACHE_DIR="${IPC_E2E_CACHE_DIR:-$HOME/.cache/toops-e2e}"

die() { echo "[new-customer] ERROR: $*" >&2; exit 1; }

customer="${1:-}"
[ -n "$customer" ] || die 'usage: provision/new-customer-installer.sh "Customer Name" [unit-number]'

slug="$(printf '%s' "$customer" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40 | sed -E 's/-+$//')"
[ -n "$slug" ] || die "customer name needs at least one letter or digit"

unit="${2:-}"
if [ -z "$unit" ]; then
  unit=1
  while [ -e "$PRIVATE_DIR/console-passwords/ipc-$slug-$(printf '%02d' "$unit")" ] \
     || [ -e "$CACHE_DIR/media/ipc-$slug-$(printf '%02d' "$unit")" ]; do
    unit=$((unit + 1))
  done
fi
[[ "$unit" =~ ^[0-9]+$ ]] && [ "$unit" -ge 1 ] && [ "$unit" -le 99 ] || die "unit number must be 1-99"
hostname="ipc-$slug-$(printf '%02d' "$unit")"
media_dir="$CACHE_DIR/media/$hostname"

tag="${IPC_E2E_IMAGE_TAG:-}"
if [ -z "$tag" ] && [ -s "$PRIVATE_DIR/seed.env" ]; then
  tag="$(sed -n -E 's/^SITE_AGENT_VERSION=(.+)$/\1/p' "$PRIVATE_DIR/seed.env" | tail -n1 | tr -d "\"'")"
fi
[[ "$tag" =~ ^sha-[0-9a-f]{7,40}$ ]] || die "set IPC_E2E_IMAGE_TAG (or SITE_AGENT_VERSION in seed.env) to an immutable sha-<commit> tag"

echo "[new-customer] customer: $customer"
echo "[new-customer] hostname: $hostname"
echo "[new-customer] image:    $tag"

IPC_E2E_HOSTNAME="$hostname" \
IPC_E2E_IMAGE_TAG="$tag" \
IPC_E2E_MEDIA_DIR="$media_dir" \
IPC_E2E_LOCAL_STACK=0 \
  "$STACK_DIR/provision/hyperv/build-media.sh"

cat <<EOF

Installer ready: $media_dir/ubuntu-ipc-autoinstall.iso

Onboarding checklist for $customer ($hostname)
  1. Cloud > Platform: create "$customer" (skip if it exists), then its site and site-agent.
  2. Cloud > Billing > Service Access Override: manual; Remote UI, Alerts, Optimizer on;
     expires on the trial decision date; reason "trial". Leave "may start the
     subscription" unticked until commissioning is settled.
  3. Cloud > Team: invite the customer's owner email.
  4. Send the ISO through a private, expiring link. It carries a single-use
     Tailscale key (7 days) and enrollment ticket (14 days).
  5. On the video call: flash the USB, unplug any disk they want to keep, boot
     it, and have them type "yes" at "Continue with autoinstall?". It erases the
     largest disk and powers off when installation finishes.
  6. Tailscale admin: approve "$hostname" only after matching this hostname.
  7. Cloud > Platform > Hardware: assign $hostname to "$customer", then pair it.
  8. Delete the ISO:  rm "$media_dir/ubuntu-ipc-autoinstall.iso"

Converting the trial: once commissioning is paid, tick "Customer may start the
subscription" on their Billing page. When they subscribe, the subscription
takes over from the trial override immediately.
EOF
