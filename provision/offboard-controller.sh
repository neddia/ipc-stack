#!/usr/bin/env bash
# Clear a controller whose trial ended without a purchase, then power it off.
#
#   provision/offboard-controller.sh ipc-acme-mining-01 [--keep-running]
#
# Run from the operator workstation over the tailnet, with Toops support access on.
# First put the site's drives back on the customer's own control (remote/local
# switch, run and speed source); that depends on the site and is not scripted.
#
# First uploads a final recovery backup to Cloud. On the box: stops and disables the stack and its timers, deletes containers,
# images, Influx data, site storage, secrets and device keys, removes the release
# registry trust, our SSH key and the console password, leaves the tailnet and
# powers off. Files are deleted, not shredded: someone with the disk could still
# recover fragments. The customer's hardware is theirs to reinstall.
#
# Then end the trial in Cloud:  docker compose exec api python -m app.offboard "Customer" --yes
set -euo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_DIR="${IPC_E2E_PRIVATE_DIR:-$HOME/.config/toops-e2e}"
die() { echo "[offboard] ERROR: $*" >&2; exit 1; }

host="${1:-}"
[ -n "$host" ] || die "usage: provision/offboard-controller.sh <controller-hostname> [--keep-running]"
power_off=1
[ "${2:-}" = "--keep-running" ] && power_off=0
ssh_target="${OFFBOARD_SSH_USER:-toops}@$host"

echo "[offboard] controller: $host"
ssh -o ConnectTimeout=10 "$ssh_target" 'hostname; docker ps --format "  {{.Names}}  {{.Status}}" 2>/dev/null || true' \
  || die "cannot reach $ssh_target over SSH (is Toops support access on?)"

# The automatic backup runs every few minutes; take one now so a returning
# customer is restored from exactly this state (Cloud: Replace hardware).
echo "[offboard] saving a final recovery backup to Cloud"
# Only the last line (the reason) is shown; the app's own logging stays quiet.
backup_result="$(ssh "$ssh_target" 'c=$(docker ps -q --filter label=com.docker.compose.service=site-agent | head -1)
  [ -n "$c" ] || { echo "site-agent container is not running"; exit 1; }
  docker exec "$c" /app/.venv/bin/python -c "
import logging; logging.disable(logging.CRITICAL)
from app.runtime import settings
from app.services.cloud import status
from app.services.cloud.recovery import backup_blocked, upload_recovery_bundle
if backup_blocked(settings):
    print(\"backups are paused while a hardware replacement or restore is pending\"); raise SystemExit(1)
if upload_recovery_bundle(settings):
    print(\"ok\"); raise SystemExit(0)
print(\"Cloud refused or was unreachable: \" + str(status.snapshot().get(\"recovery_sync\", {}).get(\"last_error\") or \"no detail\"))
raise SystemExit(1)" 2>/dev/null' | tail -n 1)" || true
if [ "$backup_result" = "ok" ]; then
  echo "[offboard] backup saved: configuration, learned maps, comparisons and miner identities"
else
  echo "[offboard] WARNING: Cloud did not accept a fresh backup (${backup_result:-no response}); an older automatic one may be all that is kept."
  read -r -p "Wipe anyway? Type 'no backup': " answer
  [ "$answer" = "no backup" ] || die "stopped: fix the controller's Cloud connection and run this again"
fi

echo
echo "This permanently deletes Basin from $host and takes it off the tailnet."
read -r -p "Are the site's drives back on the customer's own control? Type 'handed back': " answer
[ "$answer" = "handed back" ] || die "stopped: hand the drives back first"
read -r -p "Type the controller hostname to confirm: " answer
[ "$answer" = "$host" ] || die "stopped: hostname did not match"

remote_script="$(mktemp)"
trap 'rm -f "$remote_script"' EXIT
cat >"$remote_script" <<'REMOTE'
set -u
power_off="$1"
step() { echo "[offboard:$(hostname)] $*"; }
step "stopping Toops units"
for unit in ipc-replacement.timer ipc-replacement.service ipc-support-access.path ipc-support-access.timer \
            ipc-support-access.service ipc-firstboot.service; do
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$unit"
done
systemctl daemon-reload
step "removing containers, images and data volumes"
if command -v docker >/dev/null 2>&1; then
  docker ps -aq | xargs -r docker rm -f >/dev/null
  docker system prune -af --volumes >/dev/null
fi
step "removing the release registry trust"
if [ -s /etc/docker/daemon.json ]; then
  python3 - /etc/docker/daemon.json <<'PY'
import json, sys
path = sys.argv[1]
config = json.load(open(path))
config.pop("insecure-registries", None)
json.dump(config, open(path, "w"), indent=2)
PY
  systemctl restart docker >/dev/null 2>&1 || true
fi
step "deleting the stack, site storage, secrets and device keys"
rm -rf /opt/ipc-stack /opt/site-agent /var/lib/toops /etc/toops
step "scheduling: remove SSH key and console password, leave the tailnet$([ "$power_off" = 1 ] && echo ', power off')"
final=': > /home/toops/.ssh/authorized_keys; passwd -l toops; tailscale logout; systemctl disable --now tailscaled'
[ "$power_off" = 1 ] && final="$final; systemctl poweroff"
systemd-run --quiet --on-active=15 /bin/sh -c "$final"
step "done; this session ends in about 15 seconds"
REMOTE

scp -q "$remote_script" "$ssh_target:/tmp/toops-offboard.sh"
# sudo asks for this controller's console password (saved under $PRIVATE_DIR/console-passwords).
ssh -t "$ssh_target" "sudo bash /tmp/toops-offboard.sh $power_off; rm -f /tmp/toops-offboard.sh"

echo
if [ -s "$PRIVATE_DIR/tailscale.env" ]; then
  set -a; . "$PRIVATE_DIR/tailscale.env"; set +a
fi
python3 "$STACK_DIR/provision/remove-tailscale-device.py" "$host" \
  || echo "[offboard] Remove $host in the Tailscale admin console (Machines) if it is still listed."
rm -f "$PRIVATE_DIR/console-passwords/$host"
cat <<EOF

Controller cleared. Next:
  1. Cloud: docker compose exec api python -m app.offboard "<customer name>" --yes
  2. Tell the customer the box is off and theirs to reinstall.
EOF
